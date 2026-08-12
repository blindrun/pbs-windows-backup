<#
Full-disk backup of this PC to Proxmox Backup Server, via pbsmachinebackup.exe
(the other executable bundled in the upstream release zip). Takes a live VSS
snapshot of the WHOLE physical drive and backs it up as a bootable disk image
(FIDX) -- unlike windows-pbs-backup.ps1's folder-level pxar backups, this
captures everything: OS, installed apps, and all user data in one shot. Same
third-party alpha-tool caveats apply (unsigned, Windows Defender may
flag/slow it, requires Administrator for VSS).

CREDENTIALS ARE NEVER STORED IN THIS FILE -- same resolution order as
windows-pbs-backup.ps1: placeholder defaults, then a sidecar config file
(pbs-backup.config.ps1, see pbs-backup.config.example.ps1), then PBS_*
environment variables, then an interactive prompt for the secret. A
scheduled run cannot answer a prompt, so unattended use needs the secret in
the config file or the environment.

Usage:
  .\windows-pbs-fulldisk-backup.ps1                  # backs up \\.\PhysicalDrive0
  .\windows-pbs-fulldisk-backup.ps1 -PhysicalDrive 1 # backs up \\.\PhysicalDrive1 instead
  .\windows-pbs-fulldisk-backup.ps1 -Schedule        # also register a WEEKLY Scheduled Task
                                                      # (default: Sunday 02:00 -- full-disk
                                                      # images are heavy, nightly is overkill)

Run this from an ALREADY-OPEN PowerShell window (Run as Administrator),
not by double-clicking the file -- if it's double-clicked, Windows opens a
throwaway PowerShell host that closes itself the instant the process exits
or crashes, taking the output/error with it. This script also pauses at
the end either way so you can read the result before closing.

Not sure which drive holds your data? Run `Get-Disk` first.

Restore: there's no restore flag on pbsmachinebackup.exe itself. Use the
upstream's `pbsnbd` tool (Linux-only) to mount the FIDX image, or restore
through the PBS web UI where supported. Test a restore before relying on it.
#>
param(
    [int]$PhysicalDrive = 0,
    [switch]$Schedule,
    [string]$ScheduleDayOfWeek = "Sunday",
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

$BackupId = $env:COMPUTERNAME
$Device = "\\.\PhysicalDrive$PhysicalDrive"

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
            Write-Warning "No token secret configured. A scheduled task cannot answer a prompt -- put the secret in '$ConfigFile' or set PBS_PASSWORD for the account the task runs as (SYSTEM, for this script), or the weekly run will fail."
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

    $exeCmd = Get-Command pbsmachinebackup.exe -ErrorAction SilentlyContinue
    if ($exeCmd) {
        $exe = $exeCmd.Source
    } else {
        $local = Join-Path $PSScriptRoot "pbsmachinebackup.exe"
        if (Test-Path $local) {
            $exe = $local
        } else {
            Write-Error "pbsmachinebackup.exe not found (PATH or script folder). Download it from https://github.com/tizbac/proxmoxbackupclient_go/releases/latest"
            $exitCode = 1
            return
        }
    }

    Write-Host "Backing up $Device as $BackupId -- this can take a while for a full disk, do not close this window."
    $output = & $exe -baseurl $BaseUrl -certfingerprint $Fingerprint -authid $AuthId -secret $env:PBS_PASSWORD `
        -backupdev $Device -datastore $Datastore -namespace $Namespace -backup-id $BackupId 2>&1
    $output | ForEach-Object { Write-Host $_ }
    $outputText = $output -join "`n"

    if ($LASTEXITCODE -ne 0 -or $outputText -match 'Unauthorized|Authentication error|Error making request|missing permissions|panic:') {
        Write-Warning "Full-disk backup FAILED (exit $LASTEXITCODE) -- see output above."
        $exitCode = 1
    } else {
        Write-Host "Full-disk backup complete."
    }
}
finally {
    $env:PBS_PASSWORD = $null
    if ($Schedule) {
        $scriptPath = $MyInvocation.MyCommand.Path
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -PhysicalDrive $PhysicalDrive"
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $ScheduleDayOfWeek -At $ScheduleTime
        # Runs as SYSTEM (not the current user) -- unlike the folder-level script,
        # this one doesn't depend on $env:USERPROFILE, so it can run unattended
        # whether or not anyone is logged in, which is the point of a weekly
        # overnight job.
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName "PBS Windows Full-Disk Backup" -Action $action -Trigger $trigger -Principal $principal `
            -Description "Weekly full-disk backup of this PC to Proxmox Backup Server" -Force
        Write-Host "Scheduled weekly task registered for $ScheduleDayOfWeek $ScheduleTime (runs as SYSTEM, whether or not anyone is logged in)."
    }
    Write-Host ""
    Read-Host "Press Enter to close this window"
}

exit $exitCode
