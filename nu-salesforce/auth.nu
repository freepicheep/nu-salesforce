# Authentication commands for Salesforce.
#
# Supports the OAuth 2.0 flows used by Salesforce External Client Apps
# (Client Credentials, JWT Bearer, Device), a direct session ID, and the
# legacy SOAP username/password login (deprecated — retires June 1, 2027).

use util.nu [
    build-session
    build-jwt-assertion
    host-from-url
    login-host
    oauth-post
    sf-oauth-token
    sf-oauth-error
    xml-find-text
]

# Normalize an OAuth token-endpoint response into the fields `sf login` needs.
def normalize-token-response [resp: record auth_type: string fallback_instance?: string] {
    let access_token = ($resp.access_token? | default null)
    if ($access_token == null) {
        error make {msg: $"OAuth response did not include an access_token: ($resp | to json)"}
    }
    let instance = if (($resp.instance_url? | default "") != "") {
        host-from-url $resp.instance_url
    } else if ($fallback_instance != null and $fallback_instance != "") {
        $fallback_instance
    } else {
        error make {msg: "OAuth response did not include instance_url"}
    }
    {
        session_id: $access_token
        instance: $instance
        refresh_token: ($resp.refresh_token? | default null)
        issued_at: ($resp.issued_at? | default null)
        auth_type: $auth_type
    }
}

# OAuth 2.0 Client Credentials flow — server-to-server, no user context.
# Requires an External Client App with the flow enabled and a "Run As" user.
def oauth-client-credentials [client_id: string client_secret: string instance?: string] {
    if ($instance == null or $instance == "") {
        error make {msg: "Client Credentials flow requires --instance (your My Domain host, e.g. mydomain.my.salesforce.com)"}
    }
    let token_url = $"https://($instance)/services/oauth2/token"
    let resp = (
        sf-oauth-token $token_url {
            grant_type: "client_credentials"
            client_id: $client_id
            client_secret: $client_secret
        }
    )
    normalize-token-response $resp "client_credentials" $instance
}

# OAuth 2.0 JWT Bearer flow — server-to-server, authenticates as `username`
# by signing a JWT with the RSA private key uploaded to the External Client App.
def oauth-jwt-bearer [client_id: string key_path: path domain: string username?: string instance?: string] {
    if ($username == null or $username == "") {
        error make {msg: "JWT Bearer flow requires --username (the Salesforce user to authenticate as)"}
    }
    let host = (login-host $domain $instance)
    let token_url = $"https://($host)/services/oauth2/token"
    let audience = $"https://($host)"
    let assertion = (build-jwt-assertion $client_id $username $audience $key_path)
    let resp = (
        sf-oauth-token $token_url {
            grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer"
            assertion: $assertion
        }
    )
    normalize-token-response $resp "jwt_bearer" $instance
}

# OAuth 2.0 Device flow — for headless terminals. Displays a URL + user code,
# then polls the token endpoint until the user approves access in a browser.
# Pass `client_secret` for a confidential client (an app whose OAuth policies
# require a secret); omit it for a public client.
def oauth-device [client_id: string domain: string instance?: string scope?: string client_secret?: string] {
    let host = (login-host $domain $instance)
    let token_url = $"https://($host)/services/oauth2/token"

    let init = (
        oauth-post $token_url {
            response_type: "device_code"
            client_id: $client_id
            client_secret: $client_secret
            scope: $scope
        }
    )
    if $init.status >= 300 {
        sf-oauth-error $init.status $token_url $init.body
    }
    let dev = $init.body
    let verification = ($dev.verification_uri? | default ($dev.verification_url? | default ""))
    let user_code = ($dev.user_code? | default "")
    let device_code = ($dev.device_code? | default "")
    if ($device_code == "") {
        error make {msg: $"Device flow initialization failed: ($dev | to json)"}
    }

    print $"(ansi cyan)Action required:(ansi reset) open (ansi attr_bold)($verification)(ansi reset) and enter code (ansi attr_bold)($user_code)(ansi reset)"
    print "Waiting for approval..."

    mut interval = (($dev.interval? | default 5) | into int)
    let max_seconds = (($dev.expires_in? | default 600) | into int)
    mut waited = 0
    loop {
        sleep ($interval * 1sec)
        $waited = $waited + $interval
        let poll = (
            oauth-post $token_url {
                grant_type: "device"
                client_id: $client_id
                client_secret: $client_secret
                code: $device_code
            }
        )
        if $poll.status < 300 {
            return (normalize-token-response $poll.body "device" $instance)
        }
        let body = if (($poll.body | describe) == "string") {
            try { $poll.body | from json } catch { {} }
        } else {
            $poll.body
        }
        let err = ($body.error? | default "")
        if $err == "authorization_pending" {
            # user hasn't approved yet — keep polling
        } else if $err == "slow_down" {
            $interval = $interval + 5
        } else {
            sf-oauth-error $poll.status $token_url $poll.body
        }
        if $waited >= $max_seconds {
            error make {msg: "Device flow timed out waiting for user approval."}
        }
    }
}

# Legacy SOAP login(). Returns the session id and resolved instance host.
# Deprecated: the SOAP login() call is retired by Salesforce on June 1, 2027.
def soap-login [username: string password: string domain: string version: string token?: string] {
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

    # Parse the SOAP response XML to extract sessionId and serverUrl.
    # If content-type was XML, http post may have already parsed it into a record/table.
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

    {
        session_id: $session_id_val
        instance: (host-from-url $server_url)
    }
}

# Log in to Salesforce and set $env.SALESFORCE.
#
# The login method is chosen from the flags you provide:
#
#   Client Credentials (server-to-server, no user):
#     sf login --client-id <id> --client-secret <secret> --instance mydomain.my.salesforce.com
#
#   JWT Bearer (server-to-server, authenticates as a user via an RSA key):
#     sf login --client-id <id> --username user@example.com --jwt-key ./server.key
#
#   Device (interactive login from a headless terminal):
#     sf login --device --client-id <id>
#     # confidential client (app requires a secret):
#     sf login --device --client-id <id> --client-secret <secret>
#
#   Direct session ID:
#     sf login --session-id <token> --instance mydomain.my.salesforce.com
#
#   SOAP username/password (DEPRECATED — retires June 1, 2027):
#     sf login --username user@example.com --password XXXX --token XXXX
@example "Client Credentials flow" { sf login --client-id $env.SF_CLIENT_ID --client-secret $env.SF_CLIENT_SECRET --instance "mydomain.my.salesforce.com" }
@example "JWT Bearer flow" { sf login --client-id $env.SF_CLIENT_ID --username "user@example.com" --jwt-key "./server.key" }
@example "Device flow" { sf login --device --client-id $env.SF_CLIENT_ID }
export def --env "sf login" [
    --client-id: string # OAuth consumer key from the External Client App
    --client-secret: string # OAuth consumer secret (Client Credentials flow)
    --jwt-key: path # Path to the RSA private key for the JWT Bearer flow
    --device # Use the OAuth Device flow (interactive browser approval)
    --scope: string # OAuth scopes to request (Device flow)
    --username: string # Salesforce username (JWT Bearer sub, or SOAP login)
    --password: string # Password (SOAP login only)
    --token: string # Security token (SOAP login only)
    --session-id: string # Direct access token (alternative to a flow)
    --instance: string # My Domain host of your org (mydomain.my.salesforce.com)
    --domain: string # Login domain for login.salesforce.com endpoints: "login" (production) or "test" (sandbox). Default: "login"
    --version: string # Salesforce API version. Default: "64.0"
] {
    let domain = ($domain | default "login")
    let version = ($version | default "64.0")

    # 1. Direct session
    if ($session_id != null and $instance != null) {
        $env.SALESFORCE = (build-session $session_id $instance --version $version --domain $domain --auth-type "direct")
        print $"(ansi green)✓(ansi reset) Logged in to ($instance) \(direct session\)"
        return
    }

    # 2-4. OAuth 2.0 flows (External Client Apps)
    let session = if $device {
        if ($client_id == null) {
            error make {msg: "Device flow requires --client-id"}
        }
        oauth-device $client_id $domain $instance $scope $client_secret
    } else if ($client_id != null and $client_secret != null) {
        oauth-client-credentials $client_id $client_secret $instance
    } else if ($client_id != null and $jwt_key != null) {
        oauth-jwt-bearer $client_id $jwt_key $domain $username $instance
    } else {
        null
    }

    if ($session != null) {
        $env.SALESFORCE = (
            build-session $session.session_id $session.instance
            --version $version
            --domain $domain
            --auth-type $session.auth_type
            --refresh-token $session.refresh_token
            --issued-at $session.issued_at
        )
        let label = ($session.auth_type | str replace -a "_" " ")
        print $"(ansi green)✓(ansi reset) Logged in to ($session.instance) \(($label)\)"
        return
    }

    # 5. SOAP username/password (deprecated)
    if ($username != null and $password != null) {
        print $"(ansi yellow)⚠(ansi reset)  SOAP login\(\) is deprecated and will be retired by Salesforce on June 1, 2027."
        print $"   Migrate to an External Client App with the Client Credentials or JWT Bearer flow."
        let s = (soap-login $username $password $domain $version $token)
        $env.SALESFORCE = (build-session $s.session_id $s.instance --version $version --domain $domain --auth-type "password")
        print $"(ansi green)✓(ansi reset) Logged in to ($s.instance) as ($username)"
        return
    }

    # 6. Nothing matched
    error make {
        msg: (
            [
                "No valid login method. Provide flags for one of:"
                "  Client Credentials: --client-id <id> --client-secret <secret> --instance <mydomain>.my.salesforce.com"
                "  JWT Bearer:         --client-id <id> --username <user> --jwt-key <path/to/key.pem> [--instance <mydomain>.my.salesforce.com]"
                "  Device:             --device --client-id <id> [--client-secret <secret>] [--instance <mydomain>.my.salesforce.com]"
                "  Direct session:     --session-id <token> --instance <mydomain>.my.salesforce.com"
                "  SOAP (deprecated):  --username <user> --password <pass> --token <security-token>"
            ] | str join "\n"
        )
    }
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
        has_refresh_token: (($sf.refresh_token? | default null) != null)
        issued_at: ($sf.issued_at? | default null)
    }
}
