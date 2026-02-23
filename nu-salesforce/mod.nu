# nu-salesforce — A Nushell module for interacting with the Salesforce REST API.
#
# Usage:
#   use nu-salesforce *
#
#   # Authenticate
#   sf login --username user@example.com --password secret --token XXXXX
#
#   # Query
#   sf query "SELECT Id, Name FROM Account LIMIT 10"
#
#   # CRUD
#   sf sobject get Account 001XXXXXXXXXXXX
#   sf sobject create Account { Name: "Acme" }
#   sf sobject update Account 001XXXXXXXXXXXX { Name: "Updated" }
#   sf sobject delete Account 001XXXXXXXXXXXX
#
#   # Generic REST
#   sf rest "limits/"
#   sf apex "MyEndpoint"
#
#   # Bulk API 2.0
#   [{Name: "Acme"}, {Name: "Globex"}] | sf bulk insert Account
#   sf bulk query "SELECT Id, Name FROM Account"
#   sf tooling "query/?q=SELECT+Id+FROM+ApexClass"

# Re-export all public commands from submodules
export use auth.nu *
export use query.nu *
export use sobject.nu *
export use rest.nu *
export use bulk.nu *
export use util.nu [ load-env-file ]
