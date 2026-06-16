# Shared utility helpers for the nu-salesforce module.
# These are internal helpers — not exported from the module.
const DEFAULT_API_VERSION = "64.0"

# Build the session record that gets stored in $env.SALESFORCE
export def build-session [
    session_id: string
    instance: string
    --version: string = "64.0"
    --domain: string = "login"
    --auth-type: string = "direct"
    --refresh-token: any # OAuth refresh token, if the flow returned one
    --issued-at: any # Token issue time (epoch millis string), if known
] {
    let base_url = $"https://($instance)/services/data/v($version)/"
    {
        session_id: $session_id
        instance: $instance
        version: $version
        domain: $domain
        auth_type: $auth_type
        base_url: $base_url
        apex_url: $"https://($instance)/services/apexrest/"
        tooling_url: $"($base_url)tooling/"
        oauth2_url: $"https://($instance)/services/oauth2/"
        bulk_url: $"https://($instance)/services/async/($version)/"
        refresh_token: $refresh_token
        issued_at: $issued_at
        headers: (build-headers $session_id)
    }
}

# Build standard Salesforce REST API headers
export def build-headers [session_id: string] {
    {
        Content-Type: "application/json"
        Authorization: $"Bearer ($session_id)"
        X-PrettyPrint: "1"
        Sforce-Call-Options: "client=nu-salesforce"
    }
}

# Central HTTP helper for making Salesforce API calls.
# Returns the parsed response body (usually a record or table).
# Automatically handles error responses.
export def sf-call [
    method: string
    url: string
    --data: any # Body for POST/PATCH/PUT requests
    --params: record # Query parameters for GET requests
] {
    let sf = $env.SALESFORCE
    let headers = $sf.headers

    let response = match ($method | str upcase) {
        "GET" => {
            if ($params != null) {
                # Build query string manually
                let query_string = ($params | transpose key value | each {|kv| $"($kv.key)=($kv.value | url encode)" } | str join "&")
                let full_url = $"($url)?($query_string)"
                http get $full_url --headers $headers --full --allow-errors
            } else {
                http get $url --headers $headers --full --allow-errors
            }
        }
        "POST" => {
            if ($data != null) {
                http post $url ($data | to json) --headers $headers --content-type "application/json" --full --allow-errors
            } else {
                http post $url "" --headers $headers --content-type "application/json" --full --allow-errors
            }
        }
        "PATCH" => {
            if ($data != null) {
                http patch $url ($data | to json) --headers $headers --content-type "application/json" --full --allow-errors
            } else {
                http patch $url "" --headers $headers --content-type "application/json" --full --allow-errors
            }
        }
        "PUT" => {
            if ($data != null) {
                http put $url ($data | to json) --headers $headers --content-type "application/json" --full --allow-errors
            } else {
                http put $url "" --headers $headers --content-type "application/json" --full --allow-errors
            }
        }
        "DELETE" => {
            http delete $url --headers $headers --full --allow-errors
        }
        _ => {
            error make {msg: $"Unsupported HTTP method: ($method)"}
        }
    }

    let status = $response.status
    let body = $response.body

    # Handle error status codes
    if $status >= 300 {
        sf-error $status $url $body
    }

    # 204 No Content — return null
    if $status == 204 {
        return null
    }

    $body
}

# Raise a structured Salesforce error based on status code.
export def sf-error [status: int url: string content: any] {
    let msg = match $status {
        300 => "Salesforce: More than one record found"
        400 => "Salesforce: Malformed request"
        401 => "Salesforce: Session expired or invalid"
        403 => "Salesforce: Request refused — check permissions"
        404 => "Salesforce: Resource not found"
        _ => $"Salesforce: API error \(($status)\)"
    }

    let detail = if ($content | describe) == "string" {
        $content
    } else {
        try { $content | to json } catch { $"($content)" }
    }

    error make {msg: $"($msg)\nURL: ($url)\nResponse: ($detail)"}
}

# ── OAuth 2.0 helpers ──────────────────────────────────────────────────────

# Encode a string or binary value as URL-safe, unpadded Base64 (RFC 7515) —
# the encoding required for JSON Web Token segments.
export def b64url []: any -> string {
    encode base64 --url --nopad
}

# Extract the instance host (e.g. mydomain.my.salesforce.com) from a URL such
# as an OAuth `instance_url` or a SOAP serverUrl.
export def host-from-url [url: string] {
    $url
    | str replace "https://" ""
    | str replace "http://" ""
    | split row "/"
    | first
    | str replace "-api" ""
}

# Resolve the OAuth login host used for the JWT `aud` claim and as the token
# endpoint host for the JWT and Device flows.
#   - If an explicit instance (My Domain) is given, use it.
#   - Otherwise fall back to test/login.salesforce.com based on the domain.
export def login-host [domain: string instance?: string] {
    if ($instance != null and $instance != "") {
        $instance
    } else if ($domain == "test") {
        "test.salesforce.com"
    } else {
        "login.salesforce.com"
    }
}

# POST form-urlencoded parameters to a Salesforce OAuth token endpoint.
# Returns the full response as { status, body } without raising on errors,
# so callers (e.g. Device flow polling) can inspect expected error codes.
# `http post` form-encodes the record itself when given this content type.
export def oauth-post [token_url: string params: record] {
    let form = (
        $params
        | transpose key value
        | where value != null
        | reduce --fold {} {|it acc| $acc | upsert $it.key $it.value }
    )
    let response = (
        http post $token_url $form
        --content-type "application/x-www-form-urlencoded"
        --full
        --allow-errors
    )
    {status: $response.status body: $response.body}
}

# Request an OAuth access token, raising a structured error on failure.
# Used by the Client Credentials and JWT Bearer flows.
export def sf-oauth-token [token_url: string params: record] {
    let response = (oauth-post $token_url $params)
    if $response.status >= 300 {
        sf-oauth-error $response.status $token_url $response.body
    }
    $response.body
}

# Raise a structured error from a Salesforce OAuth token error response.
# The body is JSON like { error, error_description }, which `http post` may
# already have parsed into a record.
export def sf-oauth-error [status: int url: string content: any] {
    let body = if (($content | describe) == "string") {
        try { $content | from json } catch { {} }
    } else {
        $content
    }
    let err = ($body.error? | default $"HTTP ($status)")
    let desc = ($body.error_description? | default "")
    let detail = if ($desc == "") { $err } else { $"($err): ($desc)" }
    error make {msg: $"Salesforce OAuth error \(($status)\): ($detail)\nEndpoint: ($url)"}
}

# Build and RS256-sign a JWT assertion for the OAuth 2.0 JWT Bearer flow.
#   iss = consumer key (client id), sub = username to impersonate,
#   aud = login host URL, exp = now + 3 minutes.
# Signs `header.claims` with the RSA private key at key_path via openssl.
export def build-jwt-assertion [
    client_id: string
    username: string
    audience: string
    key_path: path
] {
    if (not ($key_path | path exists)) {
        error make {msg: $"JWT private key not found: ($key_path)"}
    }
    let header = ({alg: "RS256" typ: "JWT"} | to json --raw | b64url)
    let exp = ((date now | format date "%s" | into int) + 180)
    let claims = (
        {iss: $client_id sub: $username aud: $audience exp: $exp}
        | to json --raw
        | b64url
    )
    let signing_input = $"($header).($claims)"
    let signature = ($signing_input | openssl dgst -sha256 -sign $key_path | b64url)
    $"($signing_input).($signature)"
}

# Validate a SOQL query string for common structural issues.
# Raises a descriptive error if problems are found.
# Call this before sending a SOQL query to the Salesforce API.
export def validate-soql [soql: string] {
    let trimmed = ($soql | str trim)
    let upper = ($trimmed | str upcase)
    mut errors = []

    # Must start with SELECT
    if (not ($upper | str starts-with "SELECT")) {
        $errors = ($errors | append "Query must start with SELECT")
    }

    # Must contain FROM clause
    if (not ($upper =~ '\bFROM\b')) {
        $errors = ($errors | append "Missing FROM clause — did you forget to specify the SObject? (e.g. SELECT Id FROM Account)")
    }

    # FROM must come after SELECT (not reversed)
    if ($upper =~ '\bFROM\b') and ($upper =~ '\bSELECT\b') {
        let from_pos = ($upper | str index-of "FROM")
        let select_pos = ($upper | str index-of "SELECT")
        if $from_pos < $select_pos {
            $errors = ($errors | append "FROM must come after SELECT, not before it")
        }
    }

    # Check for empty field list (SELECT FROM ...)
    if ($upper =~ 'SELECT\s+FROM\b') {
        $errors = ($errors | append "No fields specified between SELECT and FROM")
    }

    # SELECT * is not valid SOQL
    if ($upper =~ 'SELECT\s+\*') {
        $errors = ($errors | append "SELECT * is not valid in SOQL — you must list fields explicitly (e.g. SELECT Id, Name FROM Account)")
    }

    if (not ($errors | is-empty)) {
        let error_list = ($errors | enumerate | each {|e| $"  ($e.index + 1). ($e.item)" } | str join "\n")
        error make {msg: $"Invalid SOQL query:\n($error_list)\nQuery: ($trimmed)"}
    }
}

# Convert an ISO 8601 date string or datetime to Salesforce-compatible format.
export def to-sf-datetime [dt: any] {
    # If it's already a datetime, format it; otherwise pass through as string
    if ($dt | describe) == "date" {
        $dt | format date "%Y-%m-%dT%H:%M:%S%z"
    } else {
        $dt | into string
    }
}

# Find a specific XML element by tag name in a parsed XML tree.
# The XML tree is in Nushell's `from xml` format:
#   { tag: "name", attributes: {...}, content: [...] }
# Returns the first matching element's text content, or null if not found.
export def xml-find-text [xml: record tag_name: string] {
    # Check if the current node matches
    if ($xml.tag? == $tag_name) {
        # Return the text content of this element
        let texts = ($xml.content | where tag == null | get content)
        if ($texts | is-empty) {
            return null
        }
        return ($texts | first)
    }

    # Recurse into child elements
    if ($xml.content? != null) {
        for child in ($xml.content | where tag != null) {
            let result = (xml-find-text $child $tag_name)
            if ($result != null) {
                return $result
            }
        }
    }

    null
}

export def strip-attributes [value: any] {
    let kind = ($value | describe)

    if ($kind | str starts-with "record") {
        $value
        | reject -o attributes
        | update cells {|cell| strip-attributes $cell }
    } else if ($kind | str starts-with "table") or ($kind | str starts-with "list") {
        $value | each {|item| strip-attributes $item }
    } else {
        $value
    }
}

export def format-query-records [records: any include_attributes: bool] {
    if $include_attributes {
        $records
    } else {
        strip-attributes $records
    }
}

# Loads environment variables from a file
export def --env load-env-file [path?: path = '.env'] {
    if ($path | path exists) {
        open -r $path | from kv | load-env
    } else {
        error make -u {msg: $'file `($path)` not found'}
    }
}

# Parses `KEY=value` text into a record
export def 'from kv' []: oneof<string, nothing> -> record {
    default ''
    | lines
    | parse '{key}={value}'
    | update value { from yaml }
    | transpose -dlr
    | default -e {}
}
