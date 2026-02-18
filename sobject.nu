# SObject CRUD commands for Salesforce.
# These map to the REST API endpoints for individual SObject operations.

use util.nu [ sf-call to-sf-datetime ]

# Get a Salesforce record by its ID.
@example "get an account by ID" { sf get Account 001XXXXXXXXXXXX }
@example "get a contact with specific fields" { sf get Contact 003XXXXXXXXXXXX --fields "Id,Name,Email" }
export def "sf get" [
    object: string # SObject type (e.g. Account, Lead, Contact)
    record_id: string # The Salesforce record ID
    --fields: string # Optional comma-separated list of fields to return
] {
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)sobjects/($object)/($record_id)"

    if ($fields != null) {
        sf-call "GET" $url --params {fields: $fields}
    } else {
        sf-call "GET" $url
    }
}

# Get a Salesforce record by a custom (external) ID field.
@example "get an account by external ID" { sf get-by-custom-id Account My_External_Id__c "EXT-001" }
export def "sf get-by-custom-id" [
    object: string # SObject type
    custom_id_field: string # The external ID field name
    custom_id: string # The external ID value
] {
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)sobjects/($object)/($custom_id_field)/($custom_id)"
    sf-call "GET" $url
}

# Create a new Salesforce record.
#
# Accepts data as a record (from argument or piped input).
# Returns the creation result with the new record's Id.
@example "create an account" { sf create Account {Name: "Acme Corp" Industry: "Technology"} } --result "
╭─────────┬────────────────────╮
│ id      │ 001Paxxxxxxxxxxxxx │
│ success │ true               │
│ errors  │ [list 0 items]     │
╰─────────┴────────────────────╯
"
@example "create an account piping the values into the command" { {Name: "Acme Corp"} | sf sobject create Account } --result "
╭─────────┬────────────────────╮
│ id      │ 001Paxxxxxxxxxxxxx │
│ success │ true               │
│ errors  │ [list 0 items]     │
╰─────────┴────────────────────╯
"
export def "sf create" [
    object: string # SObject type (e.g. Account, Lead)
    data?: record # Record data to create. Can also be piped in.
] {
    let input = $in
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)sobjects/($object)/"

    let body = if ($data != null) { $data } else { $input }

    if ($body == null) {
        error make {msg: "No data provided. Pass a record as an argument or pipe it in."}
    }

    sf-call "POST" $url --data $body
}

# Update an existing Salesforce record.
@example "update an account" { sf update Account 001XXXXXXXXXXXX {Name: "Updated Corp"} }
@example "update an account by piping data" { {Name: "Updated Corp"} | sf sobject update Account 001XXXXXXXXXXXX }
export def "sf update" [
    object: string # SObject type
    record_id: string # The record ID to update
    data?: record # Fields to update. Can also be piped in.
] {
    let input = $in
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)sobjects/($object)/($record_id)"

    let body = if ($data != null) { $data } else { $input }

    if ($body == null) {
        error make {msg: "No data provided. Pass a record as an argument or pipe it in."}
    }

    let result = (sf-call "PATCH" $url --data $body)
    if ($result == null) {
        # 204 No Content = success
        {success: true id: $record_id}
    } else {
        $result
    }
}

# Upsert a Salesforce record using an external ID field.
#
# If a record with the given external ID exists, it's updated.
# If not, a new record is created.
@example "upsert an account by external ID" { sf upsert Account My_External_Id__c EXT-001 {Name: "Acme"} }
export def "sf upsert" [
    object: string # SObject type
    ext_id_field: string # External ID field name
    ext_id_value: string # External ID value
    data?: record # Record data. Can also be piped in.
] {
    let input = $in
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)sobjects/($object)/($ext_id_field)/($ext_id_value)"

    let body = if ($data != null) { $data } else { $input }

    if ($body == null) {
        error make {msg: "No data provided. Pass a record as an argument or pipe it in."}
    }

    let result = (sf-call "PATCH" $url --data $body)
    if ($result == null) {
        {success: true}
    } else {
        $result
    }
}

# Delete a Salesforce record.
@example "delete an account" { sf delete Account 001XXXXXXXXXXXX }
export def "sf delete" [
    object: string # SObject type
    record_id: string # The record ID to delete
] {
    let result = (sf-call "DELETE" $"($env.SALESFORCE.base_url)sobjects/($object)/($record_id)")
    if ($result == null) {
        {success: true id: $record_id}
    } else {
        $result
    }
}

# Describe an SObject — returns its metadata (fields, relationships, etc).
@example "describe an account" { sf describe Account }
@example "get field details for an account" { sf describe Account | get fields | select name type label }
export def "sf describe" [
    object: string # SObject type
] {
    let sf = $env.SALESFORCE
    sf-call "GET" $"($sf.base_url)sobjects/($object)/describe"
}

# Get the metadata for an SObject (lighter than describe).
@example "get account metadata" { sf metadata Account }
export def "sf metadata" [
    object: string # SObject type
] {
    let sf = $env.SALESFORCE
    sf-call "GET" $"($sf.base_url)sobjects/($object)/"
}

# List records that were deleted within a date range.
@example "list deleted accounts in January 2024" { sf deleted Account --start "2024-01-01T00:00:00+00:00" --end "2024-01-31T00:00:00+00:00" }
export def "sf deleted" [
    object: string # SObject type
    --start: string # Start datetime (ISO 8601)
    --end: string # End datetime (ISO 8601)
] {
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)sobjects/($object)/deleted/"
    sf-call "GET" $url --params {start: (to-sf-datetime $start) end: (to-sf-datetime $end)}
}

# List records that were updated within a date range.
@example "list updated accounts in January 2024" { sf updated Account --start "2024-01-01T00:00:00+00:00" --end "2024-01-31T00:00:00+00:00" }
export def "sf updated" [
    object: string # SObject type
    --start: string # Start datetime (ISO 8601)
    --end: string # End datetime (ISO 8601)
] {
    let sf = $env.SALESFORCE
    let url = $"($sf.base_url)sobjects/($object)/updated/"
    sf-call "GET" $url --params {start: (to-sf-datetime $start) end: (to-sf-datetime $end)}
}
