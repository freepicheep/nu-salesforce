# nu-salesforce

A [Nushell](https://www.nushell.sh/) module for interacting with the Salesforce REST API. Query data, manage records, and call endpoints without leaving your shell.

## Features

- **Authentication** — Log in with the OAuth 2.0 flows used by Salesforce [External Client Apps](https://help.salesforce.com/s/articleView?id=xcloud.external_client_apps.htm&type=5) (Client Credentials, JWT Bearer, Device), a direct session ID, or legacy SOAP username/password (deprecated).
- **SOQL & SOSL** — Run queries and searches with built-in auto-pagination.
- **SObject CRUD** — Create, read, update, upsert, and delete records.
- **REST / Apex / Tooling** — Make arbitrary calls to any Salesforce REST endpoint.
- **Org Utilities** — Inspect API limits, describe SObjects, and list recently changed records.

## Installation

**Using [Quiver](https://github.com/freepicheep/quiver)**

First, install Quiver if you haven't already.

1. brew: `brew install freepicheep/tap/quiver`
2. mise: `mise use -g github:freepicheep/quiver`
3. cargo: `cargo install --git https://github.com/freepicheep/quiver`
4. shell script: `curl --proto '=https' --tlsv1.2 -LsSf https://github.com/freepicheep/quiver/releases/latest/download/quiver-installer.sh | sh`

Then, in your project directory, run `qv init`. This creates the `nupackage.toml` for managing dependencies and publishing your package if you choose to do so. Then, all you have to do is run `qv add freepicheep/nu-salesforce` to install this module into your project's `.nu-env/modules/` directory. Follow the instructions in the Quiver README for running code with your managed Nu environment.

**Git Clone**

Clone this repository (or copy the `nu-salesforce` directory) somewhere on your machine, then import it in your Nushell session or config:

```nu
use /path/to/nu-salesforce *
```

## Quick Start

```nu
# 1. Authenticate (OAuth 2.0 — see Authentication below for all flows)
sf login --client-id $env.SF_CLIENT_ID --client-secret $env.SF_CLIENT_SECRET --instance "mydomain.my.salesforce.com"

# 2. Query records
sf query "SELECT Id, Name FROM Account LIMIT 10"

# Keep Salesforce attributes metadata when needed
sf query --include-attributes "SELECT Id, Name FROM Account LIMIT 10"

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

## Authentication

`sf login` picks a login method from the flags you provide. The recommended methods use OAuth 2.0 against an [External Client App](https://help.salesforce.com/s/articleView?id=xcloud.external_client_apps.htm&type=5) (the successor to Connected Apps).

> **Heads up:** Salesforce is retiring the SOAP API `login()` call (username + password + security token) on **June 1, 2027**. Migrate any automation that uses it to one of the OAuth flows below. See the [retirement release note](https://help.salesforce.com/s/articleView?id=release-notes.rn_api_upcoming_retirement_258rn.htm&release=258&type=5).

### Setting up an External Client App

In Setup, create an **External Client App** (App Manager → New External Client App) and enable OAuth. Enable the OAuth flow you intend to use:

- **Client Credentials Flow** — enable it and set a *Run As* user under the app's OAuth policies. Note the **Consumer Key** and **Consumer Secret**.
- **JWT Bearer Flow** — select *Use digital signatures* and upload the X.509 certificate matching your RSA private key. Pre-authorize the running user. Note the **Consumer Key**.
- **Device Flow** — enable *Device Flow* and note the **Consumer Key**. See the Device Flow notes below for two settings that commonly cause `OAUTH_APPROVAL_ERROR_GENERIC`.

Add at least the `api` and `refresh_token` (offline access) scopes to **Selected OAuth Scopes**. The scopes you request at login must be a subset of what the app allows.

Your `--instance` is your My Domain host, usually `yourdomain.my.salesforce.com`.

> **Note:** `nu-salesforce` does not implement the browser-based **Authorization Code (web-server) flow**, so enabling *Authorization Code and Credentials Flow* (and *Require user credentials in the POST body…*) on the app has no effect on the flows below — it's neither required nor used.

### Client Credentials Flow (server-to-server, no user)

Best for headless automation. Requires the Consumer Key + Secret and a Run As user on the app.

```nu
sf login --client-id "<consumer-key>" --client-secret "<consumer-secret>" --instance "mydomain.my.salesforce.com"
```

### JWT Bearer Flow (server-to-server, runs as a user)

Authenticates as `--username` by signing a JWT with your RSA private key (signing is done via `openssl`, which must be on your `PATH`). No secret is stored.

Generate a key pair and upload `server.crt` to the External Client App:

```nu
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -keyout server.key -out server.crt
```

```nu
sf login --client-id "<consumer-key>" --username "user@example.com" --jwt-key "./server.key"
# sandbox: add --domain test ; My Domain audience: add --instance mydomain.my.salesforce.com
```

### Device Flow (interactive login from a headless terminal)

`sf login` prints a verification URL and a user code; approve it in any browser, and the CLI polls until the token is issued. A real Salesforce user still has to log in and approve, so the Consumer Key alone is not a credential.

```nu
# public client
sf login --device --client-id "<consumer-key>" --scope "api refresh_token"

# confidential client (app requires a secret — see below)
sf login --device --client-id "<consumer-key>" --client-secret "<consumer-secret>" --scope "api refresh_token"
```

Pass `--scope` to control the OAuth scopes requested (default: whatever the app grants). Use `--domain test` for a sandbox.

**App settings that matter for Device Flow:**

- **Require PKCE must be OFF.** If *Require Proof Key for Code Exchange (PKCE)…* is enabled, every device login fails with `OAUTH_APPROVAL_ERROR_GENERIC`, because device flow sends no `code_verifier`. A client secret does **not** satisfy a PKCE requirement — they are independent checks. (PKCE only applies to the authorization-code flow, which this tool doesn't use.)
- **Callback URL is a formality.** Device flow never redirects, but the field must be non-empty — e.g. `https://login.salesforce.com/services/oauth2/success`.
- **To require the client secret**, enable *Require Secret for Web Server Flow* (and *…for Refresh Token Flow*) on the app and always pass `--client-secret`. This must be enforced on the app — the tool can't enforce it, since a caller could hit Salesforce's token endpoint directly.

If a login fails, **Setup → Login History** shows the real reason behind the generic browser error.

### Direct Session ID

If you already have a session ID (for example from `UserInfo.getSessionId()` run in an Execute Anonymous window), log in directly:

```nu
sf login --session-id "<session-id>" --instance "mydomain.my.salesforce.com"
```

### SOAP username/password (deprecated)

Still supported until the June 2027 retirement; `sf login` prints a deprecation warning. You can keep credentials in a `.env` file and load them with `load-env-file`.[^1]

**Your `.env` File**
```env
SALESFORCE_USERNAME='user@example.com'
SALESFORCE_PASSWORD='xxxxxxxx'
SECURITY_TOKEN='xxxxxxxx'
```

```nu
load-env-file
sf login --username $env.SALESFORCE_USERNAME --password $env.SALESFORCE_PASSWORD --token $env.SECURITY_TOKEN
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

`sf query` and `sf query-more` remove Salesforce `attributes` records from returned records by default for cleaner Nushell tables. Use `--include-attributes` to keep that metadata, or `--raw` to inspect the full API response.

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
