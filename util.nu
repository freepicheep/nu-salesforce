# Shared utility helpers for the nu-salesforce module.
# These are internal helpers — not exported from the module.

const DEFAULT_API_VERSION = "59.0"

# Build the session record that gets stored in $env.SALESFORCE
export def build-session [
    session_id: string
    instance: string
    --version: string = "59.0"
    --domain: string = "login"
    --auth-type: string = "direct"
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
        headers: (build-headers $session_id)
    }
}

# Build standard Salesforce REST API headers
export def build-headers [session_id: string] {
    {
        Content-Type: "application/json"
        Authorization: $"Bearer ($session_id)"
        X-PrettyPrint: "1"
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
    | parse '{key}={value}'
    | update value { from yaml }
    | transpose -dlr
    | default -e {}
}
