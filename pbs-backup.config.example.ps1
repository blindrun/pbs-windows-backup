<#
Configuration for windows-pbs-backup.ps1 and windows-pbs-fulldisk-backup.ps1.

  1. Copy this file to  pbs-backup.config.ps1  in the same folder.
  2. Fill in the five values below.
  3. Restrict it -- it holds an API token secret. From an elevated prompt:
       icacls .\pbs-backup.config.ps1 /inheritance:r /grant:r "Administrators:(R)" "SYSTEM:(R)"

NEVER commit the filled-in pbs-backup.config.ps1. Only this .example file
belongs in version control.

Leaving $TokenSecret empty is fine for interactive runs -- the scripts will
prompt for it and will not persist it. A SCHEDULED task cannot answer a
prompt, so unattended runs need it set here (or in the PBS_PASSWORD
environment variable of the account the task runs as: the logged-on user for
the folder-level script, SYSTEM for the full-disk one).
#>

# PBS web endpoint, including port.
$BaseUrl = "https://pbs.example.com:8007"

# TLS cert fingerprint of that PBS host. On the PBS server:
#   proxmox-backup-manager cert info | grep -i fingerprint
# NOTE: this changes whenever the PBS certificate is renewed, which breaks
# every pinned client at once. Re-check it here after any cert change.
$Fingerprint = "REPLACE_WITH_PBS_CERT_FINGERPRINT"

# API token, as user@realm!tokenname.
# Create one on the PBS server with:
#   proxmox-backup-manager user generate-token <user>@pbs <tokenname>
# Grant DatastoreBackup on ONLY the namespace it needs -- and grant it on
# BOTH the token and its parent user. PBS evaluates token permissions as the
# INTERSECTION of the two, so a token-only grant silently yields no access.
$AuthId = "REPLACE_WITH_USER@pbs!REPLACE_WITH_TOKEN"

# Target datastore and namespace.
$Datastore = "REPLACE_WITH_DATASTORE"
$Namespace = "REPLACE_WITH_NAMESPACE"

# API token secret. Leave empty to be prompted on interactive runs.
$TokenSecret = ""
