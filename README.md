# nu-salesforce

A [Nushell](https://www.nushell.sh/) module for interacting with the Salesforce REST API. Query data, manage records, and call endpoints without leaving your shell.

## Features

- **Authentication** — Log in via username/password + security token (SOAP) or a direct session ID.
- **SOQL & SOSL** — Run queries and searches with built-in auto-pagination.
- **SObject CRUD** — Create, read, update, upsert, and delete records.
- **REST / Apex / Tooling** — Make arbitrary calls to any Salesforce REST endpoint.
- **Org Utilities** — Inspect API limits, describe SObjects, and list recently changed records.

## Installation

Clone this repository (or copy the `nu-salesforce` directory) somewhere on your machine, then import it in your Nushell session or config:

```nu
use /path/to/nu-salesforce *
```

## Quick Start

```nu
# 1. Authenticate
sf login --username "user@example.com" --password "xxxxxxxx" --token "xxxxxxxx"

# 2. Query records
sf query "SELECT Id, Name FROM Account LIMIT 10"

# 3. Create a record
sf sobject create Account { Name: "Acme Corp", Industry: "Technology" }

# 4. Update a record
sf sobject update Account 001XXXXXXXXXXXX { Name: "Updated Name" }

# 5. Delete a record
sf sobject delete Account 001XXXXXXXXXXXX

# 6. Call a generic REST endpoint
sf rest "limits/"

# 7. Check your session
sf whoami

# 8. Log out
sf logout
```

## Commands

| Command | Description |
| --- | --- |
| `sf login` | Authenticate to Salesforce |
| `sf logout` | Clear the current session |
| `sf whoami` | Show session information |
| `sf query` | Run a SOQL query |
| `sf query-more` | Fetch the next page of query results |
| `sf search` | Run a SOSL search |
| `sf quick-search` | Shorthand SOSL search |
| `sf sobject get` | Get a record by ID |
| `sf sobject get-by-custom-id` | Get a record by external ID |
| `sf sobject create` | Create a new record |
| `sf sobject update` | Update an existing record |
| `sf sobject upsert` | Upsert a record via external ID |
| `sf sobject delete` | Delete a record |
| `sf sobject describe` | Describe an SObject's metadata |
| `sf sobject metadata` | Get lightweight SObject metadata |
| `sf sobject deleted` | List records deleted in a date range |
| `sf sobject updated` | List records updated in a date range |
| `sf rest` | Generic REST API call |
| `sf apex` | Call an Apex REST endpoint |
| `sf tooling` | Call the Tooling API |
| `sf limits` | Show org API usage limits |
| `sf describe` | Describe all available SObjects |

## Learning More

Every command has built-in documentation. Use `help` to view a command's description, flags, and examples:

```nu
help sf query
help sf sobject create
help sf login
```

## Disclaimers

Most of the original code was written with Claude Opus 4.6 using Google's Antigravity. I used the excellent [simple-salesforce](https://github.com/simple-salesforce/simple-salesforce) python library to guide the llm on creating this module. I have not fully tested every feature yet and am not responsible for any unexpected behavior or misuse of this module.

## License

MIT
