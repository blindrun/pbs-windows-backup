<#
Backs up this PC's standard user folders (Desktop, Documents, Downloads,
Pictures, Videos, Music, Favorites) to Proxmox Backup Server.

PBS has NO official Windows client. This uses a third-party, alpha-quality
community reimplementation instead: pbsdirectorybackup.exe from
https://github.com/tizbac/proxmoxbackupclient_go
It's unsigned, Windows Defender may flag/slow it (up to ~25%), and its
README explicitly disclaims responsibility for data loss. Requires
Administrator (it uses VSS snapshots to read files that are in use).

CREDENTIALS ARE NEVER STORED IN THIS FILE. Settings are resolved in this
order, last one wins:
  1. the placeholder defaults below (the script refuses to run on these)
  2. a sidecar config file next to this script -- default name
     pbs-backup.config.ps1, see pbs-backup.config.example.ps1
  3. environment variables: PBS_BASEURL, PBS_FINGERPRINT, PBS_AUTHID,
     PBS_DATASTORE, PBS_NAMESPACE, PBS_PASSWORD
If the token secret is still unset after all that, the script prompts for it
interactively and does not persist it. Unattended/scheduled runs therefore
need it in the config file or the environment -- see the -Schedule note below.

Give the token the DatastoreBackup role on ONLY the namespace it needs. PBS
token permissions are the INTERSECTION of the token's ACL and its parent
user's, so grant the role on BOTH or the token gets nothing.

First-time setup:
  1. Download+extract the Windows release zip from:
     https://github.com/tizbac/proxmoxbackupclient_go/releases/latest/download/proxmoxbackupclient_go_Windows_x86_64.zip
     Place pbsdirectorybackup.exe in the SAME folder as this script (or
     anywhere in PATH).
  2. Copy pbs-backup.config.example.ps1 to pbs-backup.config.ps1 and fill it
     in. Restrict it to Administrators -- it holds an API token secret.
  3. Run this script AS ADMINISTRATOR from an ALREADY-OPEN PowerShell
     window:  .\windows-pbs-backup.ps1
     (double-clicking the file instead opens a throwaway PowerShell host
     that closes itself the instant the process exits or crashes, taking
     the output/error with it -- this script also pauses at the end
     either way so you can read the result before closing)

NOTE: this only backs up specific folders. If you need everything on the
drive (OS, installed apps, all data), use windows-pbs-fulldisk-backup.ps1
instead.

To automate nightly runs:
       .\windows-pbs-backup.ps1 -Schedule
     (registers a Windows Scheduled Task, elevated, running as the current
     user only while logged on -- re-run with -Schedule any time to change
     the time or re-create the task). A scheduled run cannot answer a
     prompt, so the secret must be in the config file or the environment.
#>
param(
    [switch]$Schedule,
    [string]$ScheduleTime = "02:00",
    [string]$ConfigFile = (Join-Path $PSScriptRoot "pbs-backup.config.ps1")
)

# --- 1. placeholder defaults (the script refuses to run on these) ---------
$BaseUrl     = "https://pbs.example.com:8007"
$Fingerprint = "REPLACE_WITH_PBS_CERT_FINGERPRINT"
$AuthId      = "REPLACE_WITH_USER@pbs!REPLACE_WITH_TOKEN"
$Datastore   = "REPLACE_WITH_DATASTORE"
$Namespace   = "REPLACE_WITH_NAMESPACE"
$TokenSecret = ""

# --- 2. sidecar config file ----------------------------------------------
if (Test-Path $ConfigFile) { . $ConfigFile }

# --- 3. environment overrides --------------------------------------------
if ($env:PBS_BASEURL)     { $BaseUrl     = $env:PBS_BASEURL }
if ($env:PBS_FINGERPRINT) { $Fingerprint = $env:PBS_FINGERPRINT }
if ($env:PBS_AUTHID)      { $AuthId      = $env:PBS_AUTHID }
if ($env:PBS_DATASTORE)   { $Datastore   = $env:PBS_DATASTORE }
if ($env:PBS_NAMESPACE)   { $Namespace   = $env:PBS_NAMESPACE }
if ($env:PBS_PASSWORD)    { $TokenSecret = $env:PBS_PASSWORD }

$exitCode = 0

try {
    # --- 4. refuse to run against placeholders ---------------------------
    $missing = @()
    if ($BaseUrl -like "*pbs.example.com*") { $missing += "BaseUrl" }
    foreach ($pair in @(@("Fingerprint",$Fingerprint), @("AuthId",$AuthId),
                        @("Datastore",$Datastore),     @("Namespace",$Namespace))) {
        if ([string]::IsNullOrWhiteSpace($pair[1]) -or $pair[1] -like "REPLACE_WITH_*") {
            $missing += $pair[0]
        }
    }
    if ($missing.Count -gt 0) {
        Write-Error ("Not configured: " + ($missing -join ", ") + ".`n" +
                     "Copy pbs-backup.config.example.ps1 to '$ConfigFile' and fill it in, " +
                     "or set the matching PBS_* environment variables.")
        $exitCode = 1
        return
    }

    # --- 5. token secret: never persisted by this script -----------------
    if ([string]::IsNullOrWhiteSpace($TokenSecret)) {
        if ($Schedule) {
            Write-Warning "No token secret configured. A scheduled task cannot answer a prompt -- put the secret in '$ConfigFile' or set PBS_PASSWORD for the account the task runs as, or the nightly run will fail."
        }
        $secure = Read-Host "PBS API token secret for $AuthId" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { $TokenSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ([string]::IsNullOrWhiteSpace($TokenSecret)) {
        Write-Error "No token secret supplied."
        $exitCode = 1
        return
    }
    $env:PBS_PASSWORD = $TokenSecret

    $BackupId = $env:COMPUTERNAME

    $exeCmd = Get-Command pbsdirectorybackup.exe -ErrorAction SilentlyContinue
    if ($exeCmd) {
        $exe = $exeCmd.Source
    } else {
        $local = Join-Path $PSScriptRoot "pbsdirectorybackup.exe"
        if (Test-Path $local) {
            $exe = $local
        } else {
            Write-Error "pbsdirectorybackup.exe not found (PATH or script folder). Download it from https://github.com/tizbac/proxmoxbackupclient_go/releases/latest"
            $exitCode = 1
            return
        }
    }

    $targets = [ordered]@{
        "Desktop"   = "$env:USERPROFILE\Desktop"
        "Documents" = "$env:USERPROFILE\Documents"
        "Downloads" = "$env:USERPROFILE\Downloads"
        "Pictures"  = "$env:USERPROFILE\Pictures"
        "Videos"    = "$env:USERPROFILE\Videos"
        "Music"     = "$env:USERPROFILE\Music"
        "Favorites" = "$env:USERPROFILE\Favorites"
    }

    # pbsdirectorybackup.exe only takes one -backupdir per run (unlike the
    # official Linux client's multi-archive syntax), so each folder gets its
    # own invocation -- they land as separate snapshots under the same
    # host/$BackupId backup group.
    $failed = @()
    foreach ($name in $targets.Keys) {
        $path = $targets[$name]
        if (-not (Test-Path $path)) {
            Write-Host "Skipping $name ($path not found)"
            continue
        }
        Write-Host "Backing up $name ($path) ..."
        # pbsdirectorybackup.exe has been observed to exit 0 even after a hard
        # failure (e.g. a 401 Unauthorized on every request) -- it just logs the
        # error and moves on. Don't trust the exit code alone; scan the actual
        # output for known failure markers too.
        $output = & $exe -baseurl $BaseUrl -certfingerprint $Fingerprint -authid $AuthId -secret $env:PBS_PASSWORD `
            -backupdir $path -datastore $Datastore -namespace $Namespace -backup-id $BackupId 2>&1
        $output | ForEach-Object { Write-Host $_ }
        $outputText = $output -join "`n"
        if ($LASTEXITCODE -ne 0 -or $outputText -match 'Unauthorized|Authentication error|Error making request|missing permissions|panic:') {
            Write-Warning "$name backup failed (exit $LASTEXITCODE)"
            $failed += $name
        }
    }

    if ($failed.Count -gt 0) {
        Write-Warning "Backup(s) FAILED: $($failed -join ', ') -- see output above."
        $exitCode = 1
    } else {
        Write-Host "All backups complete."
    }

    if ($Schedule) {
        $scriptPath = $MyInvocation.MyCommand.Path
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -Daily -At $ScheduleTime
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName "PBS Windows Backup" -Action $action -Trigger $trigger -Principal $principal `
            -Description "Nightly backup of user folders to Proxmox Backup Server" -Force
        Write-Host "Scheduled nightly task registered for $ScheduleTime (elevated, runs only while logged on)."
    }
}
finally {
    $env:PBS_PASSWORD = $null
    Write-Host ""
    Read-Host "Press Enter to close this window"
}

exit $exitCode
