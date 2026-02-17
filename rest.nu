# Generic REST, Apex, and Tooling API commands for Salesforce.

use util.nu [sf-call]

# Make a generic REST API call to Salesforce.
#
# The path is relative to the base REST URL
# (e.g. /services/data/v59.0/).
@example "list sobjects" { sf rest "sobjects" }
@example "reset a user password" { sf rest "sobjects/User/005.../password" --method POST --data { NewPassword: "secret" } }
@example "get org limits" { sf rest "limits/" }
export def "sf rest" [
    path: string             # Path relative to the base REST URL
    --method: string = "GET" # HTTP method (GET, POST, PATCH, PUT, DELETE)
    --data: any              # Request body for POST/PATCH/PUT
] {
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)($path)"
    sf-call $method $url --data $data
}

# Make a call to a Salesforce Apex REST endpoint.
#
# The action is appended to the Apex REST base URL
# (/services/apexrest/).
@example "call a custom Apex endpoint" { sf apex "MyCustomEndpoint" }
@example "post data to a custom Apex endpoint" { sf apex "MyCustomEndpoint" --method POST --data { key: "value" } }
export def "sf apex" [
    action: string            # Apex REST endpoint path
    --method: string = "GET"  # HTTP method
    --data: any               # Request body for POST/PATCH/PUT
] {
    let sf = $env.SALESFORCE
    let url = $"($sf.apex_url)($action)"
    sf-call $method $url --data $data
}

# Make a call to the Salesforce Tooling API.
#
# The action is appended to the Tooling API base URL.
@example "query Apex classes via Tooling API" { sf tooling "query/?q=SELECT+Id+FROM+ApexClass+LIMIT+5" }
@example "list ApexClass sobjects" { sf tooling "sobjects/ApexClass" }
export def "sf tooling" [
    action: string            # Tooling API endpoint path
    --method: string = "GET"  # HTTP method
    --data: any               # Request body for POST/PATCH/PUT
] {
    let sf = $env.SALESFORCE
    let url = $"($sf.tooling_url)($action)"
    sf-call $method $url --data $data
}

# Show the organization's API usage limits.
@example "show all API limits" { sf limits }
@example "get daily API request limits" { sf limits | get DailyApiRequests }
export def "sf limits" [] {
    let sf = $env.SALESFORCE
    sf-call "GET" $"($sf.base_url)limits/"
}

# Describe all available SObjects in the org.
@example "describe all sobjects" { sf describe }
@example "list sobject names and labels" { sf describe | get sobjects | select name label }
export def "sf describe" [] {
    let sf = $env.SALESFORCE
    sf-call "GET" $"($sf.base_url)sobjects"
}
