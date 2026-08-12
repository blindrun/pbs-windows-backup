# pbs-windows-backup

PowerShell wrappers for backing up a **physical Windows PC** to **Proxmox Backup Server**.

Proxmox Backup Server ships no official Windows client. The community filled that gap with
[tizbac/proxmoxbackupclient_go](https://github.com/tizbac/proxmoxbackupclient_go), a Go
reimplementation — but it's a bare CLI, so getting a real backup running still means working out
token scoping, VSS, scheduled tasks, and a couple of failure modes that don't announce themselves.

These scripts are that missing layer. They are **not** a PBS client; they drive the upstream one.

- **`windows-pbs-backup.ps1`** — the standard user folders (Desktop, Documents, Downloads,
  Pictures, Videos, Music, Favorites), as file-level `pxar` snapshots. Nightly by default.
- **`windows-pbs-fulldisk-backup.ps1`** — a whole physical drive as a bootable `FIDX` disk image
  via a live VSS snapshot: OS, apps and data in one shot. Weekly by default, since these are heavy.

## Requirements

- Proxmox Backup Server reachable from the PC, with a datastore you can write to
- `pbsdirectorybackup.exe` and/or `pbsmachinebackup.exe` from
  [the upstream releases](https://github.com/tizbac/proxmoxbackupclient_go/releases/latest),
  placed next to the script or anywhere in `PATH`
- Windows PowerShell 5.1+ , run **as Administrator** (both scripts use VSS to read files in use)

## Setup

**1. Create a scoped token on the PBS server.**

```bash
proxmox-backup-manager user create backups@pbs
proxmox-backup-manager user generate-token backups@pbs mypc      # prints the secret ONCE
proxmox-backup-manager acl update /datastore/mystore/mypc DatastoreBackup --auth-id 'backups@pbs'
proxmox-backup-manager acl update /datastore/mystore/mypc DatastoreBackup --auth-id 'backups@pbs!mypc'
```

Both ACL lines are required. **PBS evaluates an API token's permissions as the intersection of the
token's own ACL and its parent user's** — grant the role only on the token and it silently gets
nothing, which surfaces as an authentication failure that looks like a bad secret.

Prefer one token *per machine*: they're independently revocable, so retiring a PC doesn't mean
rotating a credential every other machine also uses.

**2. Get the certificate fingerprint** (on the PBS server):

```bash
proxmox-backup-manager cert info | grep -i fingerprint
```

**3. Configure the scripts.** Copy `pbs-backup.config.example.ps1` to `pbs-backup.config.ps1`,
fill in the five values, and lock it down — it holds the token secret:

```powershell
icacls .\pbs-backup.config.ps1 /inheritance:r /grant:r "Administrators:(R)" "SYSTEM:(R)"
```

`pbs-backup.config.ps1` is gitignored. Never commit a filled-in copy.

## Credentials

No credential is stored in the scripts. Settings resolve in order, last one wins:

1. placeholder defaults — **the scripts refuse to run on these**, rather than failing obscurely
   partway through a backup
2. `pbs-backup.config.ps1` next to the script (override the path with `-ConfigFile`)
3. environment: `PBS_BASEURL`, `PBS_FINGERPRINT`, `PBS_AUTHID`, `PBS_DATASTORE`, `PBS_NAMESPACE`,
   `PBS_PASSWORD`
4. an interactive prompt for the secret, which is **not** persisted

`PBS_PASSWORD` is cleared from the environment when the script exits.

## Usage

```powershell
.\windows-pbs-backup.ps1                       # back up user folders now
.\windows-pbs-backup.ps1 -Schedule             # ...and register a nightly task (02:00)

.\windows-pbs-fulldisk-backup.ps1              # image \\.\PhysicalDrive0
.\windows-pbs-fulldisk-backup.ps1 -PhysicalDrive 1
.\windows-pbs-fulldisk-backup.ps1 -Schedule    # ...and register a weekly task (Sunday 02:00)
```

Run from an **already-open** PowerShell window. Double-clicking a `.ps1` opens a throwaway host
that closes the instant the process exits, taking the error with it — both scripts pause at the
end anyway so you can read the result.

Not sure which disk you want? `Get-Disk`.

Snapshots land under the backup group `host/$env:COMPUTERNAME`.

### Scheduling

The folder-level task runs as the logged-on user (it needs `$env:USERPROFILE`), elevated, only
while that user is logged on. The full-disk task runs as `SYSTEM`, so it works whether or not
anyone is logged in.

A scheduled run cannot answer a prompt, so unattended use needs the secret in the config file or
in the environment of the account the task runs as. Both scripts warn about this at `-Schedule`
time rather than letting you discover it from a silently failing job.

## Traps worth knowing

- **The upstream tool can exit `0` after failing completely.** A run where every request returns
  401 still exits zero — it logs the error and moves on. Both scripts therefore scan the output
  for failure markers (`Unauthorized`, `Authentication error`, `missing permissions`, `panic:`)
  instead of trusting the exit code, and report a real non-zero status.
- **The certificate fingerprint changes on every PBS cert renewal**, and it breaks every pinned
  client simultaneously. If all your Windows PCs fail at once, check this first.
- **One folder per invocation.** `pbsdirectorybackup.exe` accepts a single `-backupdir` and has no
  equivalent of the Linux client's multi-archive syntax, so the folder-level script loops and each
  folder becomes its own snapshot in the same group.
- **Windows Defender may flag or slow the unsigned binaries**, by up to ~25% in practice.

## Restore

File-level `pxar` snapshots restore through the PBS web UI or `proxmox-backup-client` like any
other. Full-disk `FIDX` images are the weaker story: `pbsmachinebackup.exe` has no restore flag, so
you mount the image with upstream's Linux-only `pbsnbd` tool, or restore via the web UI where
supported. **Test a restore before you rely on either.**

## Credits and licence

The actual backup work is done by [tizbac/proxmoxbackupclient_go](https://github.com/tizbac/proxmoxbackupclient_go),
which is **GPL-3.0** and is *not* included here — download it from upstream. It self-describes as
in-development and its README disclaims responsibility for data loss; that applies equally to
anything you back up through these wrappers.

These wrapper scripts are MIT (see `LICENSE`). They invoke the upstream binary as a separate
process and include none of its code.

Not affiliated with Proxmox Server Solutions GmbH.
