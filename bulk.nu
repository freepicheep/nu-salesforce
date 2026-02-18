# Salesforce Bulk API 2.0 commands for nu-salesforce.
#
# Provides commands for large-scale data operations (insert, update, upsert,
# delete, hard-delete, query) using the Salesforce Bulk API 2.0.
#
# The Bulk API uses CSV for data transfer and is designed for loading or
# querying large sets of data. The workflow is:
#   1. Create a job
#   2. Upload CSV data (for ingest) or wait for query results
#   3. Close the job / signal upload complete
#   4. Poll until the job completes
#   5. Retrieve results (successful, failed, unprocessed records)
#
# Usage:
#   # Insert records from a Nu table
#   [{Name: "Acme"}, {Name: "Globex"}] | sf bulk insert Account
#
#   # Insert from a CSV file
#   sf bulk insert Account --file accounts.csv
#
#   # Bulk query
#   sf bulk query Account "SELECT Id, Name FROM Account"
#
#   # Check job status
#   sf bulk status <job-id>

# ─── Internal Helpers ───────────────────────────────────────────────────────

# Construct the Bulk API 2.0 URL for ingest or query jobs.
def bulk-url [
    --job-id: string # Optional job ID to append
    --query # Use the query endpoint (default is ingest)
] {
    let sf = $env.SALESFORCE
    let base = $"https://($sf.instance)/services/data/v($sf.version)/jobs/"
    let kind = if $query { "query" } else { "ingest" }
    if ($job_id != null) {
        $"($base)($kind)/($job_id)"
    } else {
        $"($base)($kind)"
    }
}

# Make a Bulk API 2.0 HTTP call.
# The Bulk API sometimes needs different Content-Type/Accept headers than
# the standard REST API (e.g. text/csv for data upload).
def bulk-call [
    method: string
    url: string
    --data: any # Body data (string or record)
    --content-type: string # Override Content-Type header
    --accept: string # Override Accept header
] {
    let sf = $env.SALESFORCE
    let ct = if ($content_type != null) { $content_type } else { "application/json" }
    let acc = if ($accept != null) { $accept } else { "application/json" }

    let headers = {
        Content-Type: $ct
        Accept: $acc
        Authorization: $"Bearer ($sf.session_id)"
        X-PrettyPrint: "1"
    }

    let response = match ($method | str upcase) {
        "GET" => {
            http get $url --headers $headers --full --allow-errors
        }
        "POST" => {
            if ($data != null) {
                http post $url $data --headers $headers --content-type $ct --full --allow-errors
            } else {
                http post $url "" --headers $headers --content-type $ct --full --allow-errors
            }
        }
        "PATCH" => {
            if ($data != null) {
                http patch $url $data --headers $headers --content-type $ct --full --allow-errors
            } else {
                http patch $url "" --headers $headers --content-type $ct --full --allow-errors
            }
        }
        "PUT" => {
            if ($data != null) {
                http put $url $data --headers $headers --content-type $ct --full --allow-errors
            } else {
                http put $url "" --headers $headers --content-type $ct --full --allow-errors
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

    if $status >= 300 {
        let body = $response.body
        let detail = if ($body | describe) == "string" {
            $body
        } else {
            try { $body | to json } catch { $"($body)" }
        }
        error make {msg: $"Bulk API error \(($status)\)\nURL: ($url)\nResponse: ($detail)"}
    }

    if $status == 204 {
        return null
    }

    $response.body
}

# Create a Bulk API 2.0 ingest job.
def bulk-create-ingest-job [
    object: string
    operation: string
    --external-id-field: string
] {
    let url = (bulk-url)

    let payload = {
        object: $object
        operation: $operation
        contentType: "CSV"
        lineEnding: "LF"
        columnDelimiter: "COMMA"
    }

    let payload = if ($external_id_field != null) {
        $payload | insert externalIdFieldName $external_id_field
    } else {
        $payload
    }

    bulk-call "POST" $url --data ($payload | to json)
}

# Upload CSV data to an open ingest job.
def bulk-upload-data [
    job_id: string
    csv_data: string
] {
    let url = $"(bulk-url --job-id $job_id)/batches"
    bulk-call "PUT" $url --data $csv_data --content-type "text/csv; charset=UTF-8" --accept "application/json"
}

# Signal that all data has been uploaded (set state to UploadComplete).
def bulk-close-job [job_id: string] {
    let url = (bulk-url --job-id $job_id)
    let payload = {state: "UploadComplete"} | to json
    bulk-call "PATCH" $url --data $payload
}

# Get the status/info of a job (ingest or query).
def bulk-get-job [
    job_id: string
    --query # Whether this is a query job
] {
    let url = if $query {
        bulk-url --job-id $job_id --query
    } else {
        bulk-url --job-id $job_id
    }
    bulk-call "GET" $url
}

# Poll a job until it reaches a terminal state (JobComplete, Aborted, Failed).
# Returns the final job info record.
def bulk-wait-for-job [
    job_id: string
    --query # Whether this is a query job
    --poll-interval: duration = 500ms # Time between status checks
    --timeout: duration = 24hr # Max wait time before giving up
] {
    let start = (date now)
    mut delay = $poll_interval
    mut job_info = null

    # Initial sleep before first poll
    sleep $poll_interval

    loop {
        $job_info = if $query {
            bulk-get-job $job_id --query
        } else {
            bulk-get-job $job_id
        }

        let state = $job_info.state

        if $state == "JobComplete" or $state == "Aborted" or $state == "Failed" {
            if $state == "Failed" {
                let error_msg = if ($job_info.errorMessage? != null) {
                    $job_info.errorMessage
                } else {
                    $job_info | to json
                }
                error make {msg: $"Bulk job failed: ($error_msg)"}
            }
            if $state == "Aborted" {
                error make {msg: "Bulk job was aborted"}
            }
            return $job_info
        }

        let elapsed = (date now) - $start
        if $elapsed > $timeout {
            error make {msg: $"Bulk job timed out after ($timeout). Last state: ($state)"}
        }

        sleep $delay

        # Exponential backoff up to 2 seconds
        let next_delay_ns = ($delay | into int) + ([1 ($delay | into int)] | math max)
        let max_ns = (2sec | into int)
        $delay = if $next_delay_ns > $max_ns {
            2sec
        } else {
            $"($next_delay_ns)ns" | into duration
        }
    }
}

# Convert a Nu table (list of records) to CSV string for the Bulk API.
def table-to-csv []: table -> string {
    $in | to csv
}

# ─── Ingest Operation (shared by insert/update/upsert/delete/hard_delete) ──

# Core ingest workflow: create job → upload CSV → close → poll → return summary.
def bulk-ingest [
    object: string
    operation: string # insert, update, upsert, delete, hardDelete
    csv_data: string
    --external-id-field: string
    --poll-interval: duration = 500ms
    --timeout: duration = 24hr
] {
    # 1. Create the job
    let job = (bulk-create-ingest-job $object $operation --external-id-field $external_id_field)
    let job_id = $job.id

    if $job.state != "Open" {
        error make {msg: $"Bulk job creation returned unexpected state: ($job.state)"}
    }

    # 2. Upload the CSV data
    try {
        bulk-upload-data $job_id $csv_data

        # 3. Close the job (signal UploadComplete)
        bulk-close-job $job_id

        # 4. Wait for processing to complete
        let result = (bulk-wait-for-job $job_id --poll-interval $poll_interval --timeout $timeout)

        # 5. Return a summary
        {
            job_id: $job_id
            state: $result.state
            operation: $operation
            object: $object
            records_processed: ($result.numberRecordsProcessed? | default 0 | into int)
            records_failed: ($result.numberRecordsFailed? | default 0 | into int)
        }
    } catch {|e|
        # If something goes wrong, try to abort the job
        try { bulk-abort-ingest-job $job_id } catch { }
        $e.msg | error make {msg: $"Bulk ($operation) failed: ($in)"}
    }
}

# Abort an ingest job.
def bulk-abort-ingest-job [job_id: string] {
    let url = (bulk-url --job-id $job_id)
    let payload = {state: "Aborted"} | to json
    bulk-call "PATCH" $url --data $payload
}

# ─── Public Commands ────────────────────────────────────────────────────────

# Insert records into Salesforce using the Bulk API 2.0.
#
# Accepts a table of records from the pipeline or a CSV file path.
# Returns a summary with the job ID and record counts.
@example "insert accounts from a table" {
    [{Name: "Acme" Industry: "Tech"} {Name: "Globex" Industry: "Manufacturing"}] | sf bulk insert Account
}
@example "insert from a CSV file" {
    sf bulk insert Account --file accounts.csv
}
export def "sf bulk insert" [
    object: string # SObject type (e.g. Account, Lead)
    --file: path # Path to a CSV file to upload
    --poll-interval: duration = 500ms # Time between status checks
    --timeout: duration = 24hr # Max wait time
] {
    let input = $in
    let csv_data = if ($file != null) {
        open --raw $file
    } else if ($input != null) {
        $input | table-to-csv
    } else {
        error make {msg: "No data provided. Pipe in a table or use --file."}
    }

    bulk-ingest $object "insert" $csv_data --poll-interval $poll_interval --timeout $timeout
}

# Update existing records in Salesforce using the Bulk API 2.0.
#
# The input data must include the Id field for each record.
@example "update accounts from a table" {
    [{Id: "001XX0000003DHP" Name: "Updated Corp"}] | sf bulk update Account
}
@example "update from a CSV file" {
    sf bulk update Account --file updates.csv
}
export def "sf bulk update" [
    object: string # SObject type (e.g. Account, Lead)
    --file: path # Path to a CSV file to upload
    --poll-interval: duration = 500ms
    --timeout: duration = 24hr
] {
    let input = $in
    let csv_data = if ($file != null) {
        open --raw $file
    } else if ($input != null) {
        $input | table-to-csv
    } else {
        error make {msg: "No data provided. Pipe in a table or use --file."}
    }

    bulk-ingest $object "update" $csv_data --poll-interval $poll_interval --timeout $timeout
}

# Upsert records in Salesforce using the Bulk API 2.0.
#
# If a record with the given external ID exists, it is updated;
# otherwise a new record is created.
@example "upsert accounts by external ID" {
    [{My_External_Id__c: "EXT-001" Name: "Acme"}] | sf bulk upsert Account --external-id-field My_External_Id__c
}
export def "sf bulk upsert" [
    object: string # SObject type (e.g. Account, Lead)
    --external-id-field: string = "Id" # The external ID field name
    --file: path # Path to a CSV file to upload
    --poll-interval: duration = 500ms
    --timeout: duration = 24hr
] {
    let input = $in
    let csv_data = if ($file != null) {
        open --raw $file
    } else if ($input != null) {
        $input | table-to-csv
    } else {
        error make {msg: "No data provided. Pipe in a table or use --file."}
    }

    bulk-ingest $object "upsert" $csv_data --external-id-field $external_id_field --poll-interval $poll_interval --timeout $timeout
}

# Delete records from Salesforce using the Bulk API 2.0.
#
# The input data must contain only the Id field.
@example "delete accounts by ID" {
    [{Id: "001XX0000003DHP"} {Id: "001XX0000003DHQ"}] | sf bulk delete Account
}
@example "delete from a CSV file" {
    sf bulk delete Account --file deletes.csv
}
export def "sf bulk delete" [
    object: string # SObject type (e.g. Account, Lead)
    --file: path # Path to a CSV file (must contain only Id column)
    --poll-interval: duration = 500ms
    --timeout: duration = 24hr
] {
    let input = $in
    let csv_data = if ($file != null) {
        open --raw $file
    } else if ($input != null) {
        $input | table-to-csv
    } else {
        error make {msg: "No data provided. Pipe in a table or use --file."}
    }

    bulk-ingest $object "delete" $csv_data --poll-interval $poll_interval --timeout $timeout
}

# Hard-delete records from Salesforce using the Bulk API 2.0.
#
# Unlike soft-delete, hard-deleted records are not recoverable
# from the Salesforce recycle bin.
# The input data must contain only the Id field.
@example "hard-delete accounts by ID" {
    [{Id: "001XX0000003DHP"}] | sf bulk hard-delete Account
}
export def "sf bulk hard-delete" [
    object: string # SObject type (e.g. Account, Lead)
    --file: path # Path to a CSV file (must contain only Id column)
    --poll-interval: duration = 500ms
    --timeout: duration = 24hr
] {
    let input = $in
    let csv_data = if ($file != null) {
        open --raw $file
    } else if ($input != null) {
        $input | table-to-csv
    } else {
        error make {msg: "No data provided. Pipe in a table or use --file."}
    }

    bulk-ingest $object "hardDelete" $csv_data --poll-interval $poll_interval --timeout $timeout
}

# Run a bulk SOQL query using the Bulk API 2.0.
#
# Creates a query job, waits for completion, and returns all results
# as a Nu table. Automatically paginates through large result sets.
@example "bulk query all accounts" {
    sf bulk query "SELECT Id, Name FROM Account"
}
@example "bulk query with deleted records" {
    sf bulk query "SELECT Id, Name FROM Account" --include-deleted
}
export def "sf bulk query" [
    soql: string # The SOQL query string
    --include-deleted # Include deleted/archived records (queryAll)
    --poll-interval: duration = 500ms
    --timeout: duration = 24hr
    --max-records: int = 50000 # Max records per result page
] {
    let sf = $env.SALESFORCE
    let operation = if $include_deleted { "queryAll" } else { "query" }

    # 1. Create the query job
    let url = (bulk-url --query)
    let payload = {
        operation: $operation
        query: $soql
        columnDelimiter: "COMMA"
        lineEnding: "LF"
    }
    let job = (bulk-call "POST" $url --data ($payload | to json))
    let job_id = $job.id

    # 2. Wait for the query to complete
    bulk-wait-for-job $job_id --query --poll-interval $poll_interval --timeout $timeout

    # 3. Retrieve results, auto-paginating through locators
    mut all_records = []
    mut locator = ""
    mut has_more = true

    while $has_more {
        let results_url = if ($locator | is-empty) {
            $"(bulk-url --job-id $job_id --query)/results?maxRecords=($max_records)"
        } else {
            $"(bulk-url --job-id $job_id --query)/results?maxRecords=($max_records)&locator=($locator)"
        }

        let response = (
            http get $results_url
            --headers {
                Authorization: $"Bearer ($sf.session_id)"
                Accept: "text/csv"
            }
            --full
            --allow-errors
            --raw
        )

        if $response.status >= 300 {
            let detail = ($response.body | describe | if $in == "string" { $response.body } else { try { $response.body | to json } catch { $"($response.body)" } })
            error make {msg: $"Bulk query results error \(($response.status)\): ($detail)"}
        }

        let csv_text = $response.body

        # Parse the CSV into a table and append
        if (not ($csv_text | str trim | is-empty)) {
            let page_records = ($csv_text | from csv --flexible)
            $all_records = ($all_records | append $page_records)
        }

        # Check for next page via Sforce-Locator header
        let next_locator = (
            $response.headers
            | default []
            | transpose name value
            | where name == "sforce-locator"
            | get -o 0.value
            | default ""
        )

        if ($next_locator | is-empty) or $next_locator == "null" {
            $has_more = false
        } else {
            $locator = $next_locator
        }
    }

    $all_records
}

# Get the status of a Bulk API 2.0 job.
#
# Returns a record with job state, record counts, and other metadata.
@example "check the status of an ingest job" {
    sf bulk status 7501T00000Abc123
}
@example "check the status of a query job" {
    sf bulk status 7501T00000Abc123 --query
}
export def "sf bulk status" [
    job_id: string # The job ID to check
    --query # Whether this is a query job (default: ingest job)
] {
    let job = if $query {
        bulk-get-job $job_id --query
    } else {
        bulk-get-job $job_id
    }

    # Return a clean summary record
    {
        id: $job.id
        state: $job.state
        operation: $job.operation
        object: ($job.object? | default "")
        created_date: ($job.createdDate? | default "")
        records_processed: ($job.numberRecordsProcessed? | default 0 | into int)
        records_failed: ($job.numberRecordsFailed? | default 0 | into int)
        error_message: ($job.errorMessage? | default "")
    }
}

# Get the successful results from a completed Bulk API 2.0 ingest job.
#
# Returns a table with sf__Id, sf__Created, and the original data fields.
@example "get successful records from an ingest job" {
    sf bulk results 7501T00000Abc123
}
export def "sf bulk results" [
    job_id: string # The job ID
] {
    let sf = $env.SALESFORCE
    let url = $"(bulk-url --job-id $job_id)/successfulResults"
    let response = (
        http get $url
        --headers {
            Authorization: $"Bearer ($sf.session_id)"
            Accept: "text/csv"
        }
        --full
        --allow-errors
        --raw
    )

    if $response.status >= 300 {
        error make {msg: $"Bulk results error \(($response.status)\): ($response.body)"}
    }

    let csv_text = $response.body
    if ($csv_text | str trim | is-empty) {
        return []
    }
    $csv_text | from csv --flexible
}

# Get the failed results from a completed Bulk API 2.0 ingest job.
#
# Returns a table with sf__Id, sf__Error, and the original data fields.
@example "get failed records from an ingest job" {
    sf bulk failures 7501T00000Abc123
}
export def "sf bulk failures" [
    job_id: string # The job ID
] {
    let sf = $env.SALESFORCE
    let url = $"(bulk-url --job-id $job_id)/failedResults"
    let response = (
        http get $url
        --headers {
            Authorization: $"Bearer ($sf.session_id)"
            Accept: "text/csv"
        }
        --full
        --allow-errors
        --raw
    )

    if $response.status >= 300 {
        error make {msg: $"Bulk failures error \(($response.status)\): ($response.body)"}
    }

    let csv_text = $response.body
    if ($csv_text | str trim | is-empty) {
        return []
    }
    $csv_text | from csv --flexible
}

# Get the unprocessed records from a Bulk API 2.0 ingest job.
#
# Returns a table of records that were not processed (e.g. due to job abort).
@example "get unprocessed records from an ingest job" {
    sf bulk unprocessed 7501T00000Abc123
}
export def "sf bulk unprocessed" [
    job_id: string # The job ID
] {
    let sf = $env.SALESFORCE
    let url = $"(bulk-url --job-id $job_id)/unprocessedRecords"
    let response = (
        http get $url
        --headers {
            Authorization: $"Bearer ($sf.session_id)"
            Accept: "text/csv"
        }
        --full
        --allow-errors
        --raw
    )

    if $response.status >= 300 {
        error make {msg: $"Bulk unprocessed error \(($response.status)\): ($response.body)"}
    }

    let csv_text = $response.body
    if ($csv_text | str trim | is-empty) {
        return []
    }
    $csv_text | from csv --flexible
}

# Abort a running Bulk API 2.0 job.
@example "abort an ingest job" {
    sf bulk abort 7501T00000Abc123
}
@example "abort a query job" {
    sf bulk abort 7501T00000Abc123 --query
}
export def "sf bulk abort" [
    job_id: string # The job ID to abort
    --query # Whether this is a query job
] {
    let url = if $query {
        bulk-url --job-id $job_id --query
    } else {
        bulk-url --job-id $job_id
    }
    let payload = {state: "Aborted"} | to json
    let result = (bulk-call "PATCH" $url --data $payload)
    {
        id: $job_id
        state: "Aborted"
        message: "Job abort requested"
    }
}

# Delete a Bulk API 2.0 job.
#
# Removes the job and its associated data from Salesforce.
# The job must be in a terminal state (JobComplete, Aborted, or Failed).
@example "delete an ingest job" {
    sf bulk delete-job 7501T00000Abc123
}
@example "delete a query job" {
    sf bulk delete-job 7501T00000Abc123 --query
}
export def "sf bulk delete-job" [
    job_id: string # The job ID to delete
    --query # Whether this is a query job
] {
    let url = if $query {
        bulk-url --job-id $job_id --query
    } else {
        bulk-url --job-id $job_id
    }
    bulk-call "DELETE" $url
    {
        id: $job_id
        deleted: true
    }
}

# List all Bulk API 2.0 ingest jobs.
@example "list all ingest jobs" { sf bulk list-jobs }
export def "sf bulk list-jobs" [
    --query # List query jobs instead of ingest jobs
] {
    let url = if $query {
        bulk-url --query
    } else {
        bulk-url
    }
    let result = (bulk-call "GET" $url)
    $result.records? | default []
}
