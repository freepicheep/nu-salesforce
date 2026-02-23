# SOQL query and SOSL search commands for Salesforce.

use util.nu [ sf-call validate-soql ]

# Run a SOQL query against Salesforce.
#
# Returns the records as a table by default.
# Use --raw to get the full Salesforce response (includes totalSize, done, etc).
# Use --all to auto-paginate through all result pages.
# Use --include-deleted to query deleted/archived records (uses queryAll/ endpoint).
@example "query accounts" { sf query "SELECT Id, Name FROM Account LIMIT 10" }
@example "query all leads with auto-pagination" { sf query --all "SELECT Id, Name FROM Lead" }
@example "get raw query response" { sf query --raw "SELECT Id FROM Contact" }
@example "query deleted records" { sf query "SELECT Id FROM Account WHERE IsDeleted = true" --include-deleted }
export def "sf query" [
    soql: string # The SOQL query string
    --all # Auto-paginate to fetch all records
    --raw # Return the raw Salesforce JSON response
    --include-deleted # Include deleted/archived records (queryAll endpoint)
] {
    # basic soql validation before hitting the Salesforce API
    validate-soql $soql

    let sf = $env.SALESFORCE
    let endpoint = if $include_deleted { "queryAll/" } else { "query/" }
    let url = $"($sf.base_url)($endpoint)"

    let result = (sf-call "GET" $url --params {q: $soql})

    if $raw {
        return $result
    }

    if $all {
        # Auto-paginate: collect all records across pages
        mut all_records = ($result.records)
        mut current = $result

        while (not $current.done) {
            let next_url = $"https://($sf.instance)($current.nextRecordsUrl)"
            $current = (sf-call "GET" $next_url)
            $all_records = ($all_records | append $current.records)
        }

        # reject attributes column for clean output
        $all_records | reject -o attributes
    } else {
        # reject attributes column for clean output
        $result.records | reject -o attributes
    }
}

# Fetch the next page of results from a previous query.
#
# Use this when you get partial results and want manual pagination control.
# Pass the nextRecordsUrl from a --raw query response.
@example "fetch the next page of query results" { let page1 = (sf query --raw "SELECT Id FROM Account"); if (not $page1.done) { sf query-more $page1.nextRecordsUrl } }
export def "sf query-more" [
    next_records_url: string # The nextRecordsUrl from a previous query response
    --raw # Return the raw Salesforce JSON response
] {
    let sf = $env.SALESFORCE
    let url = $"https://($sf.instance)($next_records_url)"
    let result = (sf-call "GET" $url)

    if $raw {
        return $result
    }

    $result.records | reject -o attributes
}

# Run a SOSL search against Salesforce.
#
# Pass the full SOSL query string (e.g. "FIND {Waldo}").
@example "search for accounts matching Acme" { sf search "FIND {Acme} IN ALL FIELDS RETURNING Account(Id, Name)" }
export def "sf search" [
    sosl: string # The SOSL search string
] {
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)search/"
    sf-call "GET" $url --params {q: $sosl}
}

# Run a quick SOSL search — wraps the search term in FIND {...}.
@example "quick search for Acme" { sf quick-search "Acme" }
export def "sf quick-search" [
    term: string # The search term (will be wrapped in FIND {...})
] {
    sf search $"FIND {($term)}"
}
