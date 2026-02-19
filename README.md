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
sf create Account { Name: "Acme Corp", Industry: "Technology" }

# 4. Update a record
sf update Account 001XXXXXXXXXXXX { Name: "Updated Name" }

# 5. Delete a record
sf delete Account 001XXXXXXXXXXXX

# 6. Call a generic REST endpoint
sf rest "limits/"

# 7. Check your session
sf whoami

# 8. Log out
sf logout
```

### Credential Management

**With Email, Password, and Security Token**

If you store your Salesforce username, password, and security token in a `.env` file, you can use the `load-env-file` function to add those to your environment variables.[^1]

**Your `.env` File**
```env
SALESFORCE_USERNAME='user@example.com'
SALESFORCE_PASSWORD='xxxxxxxx'
SECURITY_TOKEN='xxxxxxxx'
```

**In Your Script**
```nu
use /path/to/nu-salesforce * 

# load your salesforce credentials from the .env file
load-env-file

# login to salesforce with your credentials
sf login --username $env.SALESFORCE_USERNAME --password $env.SALESFORCE_PASSWORD --token $env.SECURITY_TOKEN
```

**With Session Id and Instance**

If you want to login using a session id, you can obtain it several ways. One way is to run the following script in an "Execute Anonymous Window" and copy the id from the debug output in the console.

```apex
String id = UserInfo.getSessionId().Substring(15);

System.debug('My session id: ' + id);
```

Your instance is usually `yourdomain.my.salesforce.com`.

You can then log in to nu-salesforce like this:

```nu
sf login --session 'your_session_id' --instance 'yourdomain.my.salesforce.com'
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
| `sf get` | Get a record by ID |
| `sf get-by-custom-id` | Get a record by external ID |
| `sf create` | Create a new record |
| `sf update` | Update an existing record |
| `sf upsert` | Upsert a record via external ID |
| `sf delete` | Delete a record |
| `sf describe` | Describe an SObject's metadata |
| `sf metadata` | Get lightweight SObject metadata |
| `sf deleted` | List records deleted in a date range |
| `sf updated` | List records updated in a date range |
| `sf rest` | Generic REST API call |
| `sf apex` | Call an Apex REST endpoint |
| `sf tooling` | Call the Tooling API |
| `sf limits` | Show org API usage limits |
| `sf describe-all` | Describe all available SObjects |
| `load-env-file` | Loads key-value data from a .env file |

## Learning More

Every command has built-in documentation. Use `help` to view a command's description, flags, and examples:

```nu
help sf query
help sf create
help sf login
```

## Disclaimers

Most of the original code was written with Claude Opus 4.6 using Google's Antigravity. I used the excellent [simple-salesforce](https://github.com/simple-salesforce/simple-salesforce) python library to guide the llm on creating this module. I have not fully tested every feature yet and am not responsible for any unexpected behavior or misuse of this module.

## License

MIT

[^1]: Thanks to `@pixl_xip` on the nushell Discord for this handy function.
