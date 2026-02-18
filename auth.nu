# Authentication commands for Salesforce.
# Supports password+token (SOAP login) and direct session ID.

use util.nu [ build-session xml-find-text ]

# Log in to Salesforce and set $env.SALESFORCE.
#
# Supports two modes:
# 1. Password + Security Token (SOAP login):
#      sf login --username user@example.com --password secret --token XXXXX
# 2. Direct session access:
#      sf login --session-id 00D... --instance na1.salesforce.com
export def --env "sf login" [
    --username: string # Salesforce username
    --password: string # Password for the username
    --token: string # Security token for the username
    --session-id: string # Direct access token (alternative to user/pass)
    --instance: string # Domain of your Salesforce instance (e.g. na1.salesforce.com)
    --domain: string # Login domain: "login" (production) or "test" (sandbox). Default: "login"
    --version: string # Salesforce API version. Default: "59.0"
] {
    let domain = if ($domain != null) { $domain } else { "login" }
    let version = if ($version != null) { $version } else { "59.0" }

    if ($session_id != null and $instance != null) {
        # Direct session path
        $env.SALESFORCE = (build-session $session_id $instance --version $version --domain $domain --auth-type "direct")
        print $"(ansi green)✓(ansi reset) Logged in to ($instance) \(direct session\)"
        return
    }

    if ($username == null or $password == null) {
        error make {msg: "You must provide either --username/--password/--token or --session-id/--instance"}
    }

    # SOAP login with username + password + optional security token
    let security_token = if ($token != null) { $token } else { "" }

    let soap_body = (
        [
            '<?xml version="1.0" encoding="utf-8" ?>'
            '<env:Envelope'
            '    xmlns:xsd="http://www.w3.org/2001/XMLSchema"'
            '    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
            '    xmlns:env="http://schemas.xmlsoap.org/soap/envelope/"'
            '    xmlns:urn="urn:partner.soap.sforce.com">'
            '  <env:Header>'
            '    <urn:CallOptions>'
            $'      <urn:client>nu-salesforce</urn:client>'
            '      <urn:defaultNamespace>sf</urn:defaultNamespace>'
            '    </urn:CallOptions>'
            '  </env:Header>'
            '  <env:Body>'
            '    <n1:login xmlns:n1="urn:partner.soap.sforce.com">'
            $'      <n1:username>($username)</n1:username>'
            $'      <n1:password>($password)($security_token)</n1:password>'
            '    </n1:login>'
            '  </env:Body>'
            '</env:Envelope>'
        ] | str join "\n"
    )

    let soap_url = $"https://($domain).salesforce.com/services/Soap/u/($version)"

    let response = (
        http post $soap_url $soap_body
        --content-type "text/xml"
        --headers {SOAPAction: "login" charset: "UTF-8"}
        --full
        --allow-errors
    )

    if $response.status != 200 {
        # Try to extract error message from SOAP fault
        let error_msg = try {
            let xml = if ($response.body | describe | str starts-with "record") {
                $response.body
            } else {
                $response.body | from xml
            }
            let fault = (xml-find-text $xml "faultstring")
            if ($fault != null) { $fault } else {
                let sf_msg = (xml-find-text $xml "sf:exceptionMessage")
                if ($sf_msg != null) { $sf_msg } else { $"HTTP ($response.status)" }
            }
        } catch {
            $"HTTP ($response.status): ($response.body)"
        }
        error make {msg: $"Salesforce authentication failed: ($error_msg)"}
    }

    # Parse the SOAP response XML to extract sessionId and serverUrl
    # If content-type was XML, http post may have already parsed it into a record/table
    let xml = if ($response.body | describe | str starts-with "record") {
        $response.body
    } else {
        $response.body | from xml
    }
    let session_id_val = (xml-find-text $xml "sessionId")
    let server_url = (xml-find-text $xml "serverUrl")

    if ($session_id_val == null or $server_url == null) {
        error make {msg: "Salesforce authentication failed: could not extract sessionId or serverUrl from response"}
    }

    # Extract the instance hostname from the serverUrl
    # serverUrl looks like: https://na1.salesforce.com/services/Soap/u/59.0/00D...
    let sf_instance = (
        $server_url
        | str replace "https://" ""
        | str replace "http://" ""
        | split row "/"
        | first
        | str replace "-api" ""
    )

    $env.SALESFORCE = (build-session $session_id_val $sf_instance --version $version --domain $domain --auth-type "password")
    print $"(ansi green)✓(ansi reset) Logged in to ($sf_instance) as ($username)"
}

# Clear the Salesforce session.
export def --env "sf logout" [] {
    if ("SALESFORCE" not-in $env) {
        print "Not logged in."
        return
    }
    $env.SALESFORCE = null
    print $"(ansi yellow)✓(ansi reset) Logged out of Salesforce"
}

# Show current Salesforce session information.
export def "sf whoami" [] {
    if ("SALESFORCE" not-in $env or $env.SALESFORCE == null) {
        print "Not logged in. Use `sf login` first."
        return
    }

    let sf = $env.SALESFORCE
    {
        instance: $sf.instance
        version: $sf.version
        auth_type: $sf.auth_type
        domain: $sf.domain
        base_url: $sf.base_url
    }
}
