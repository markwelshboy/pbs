# Installation and configuration

## Prerequisites

- Proxmox Backup Server 4.x
- datastore `pbs-sas` mounted at `/mnt/datastore/pbs-sas`
- `jq`, `rclone`, `smartmontools`, `openssl`
- a working NFS mount to the NUC-hosted NAS disk
- existing rclone S3 remote `amazon_s3_backup`
- optional `telegram-send` configuration

## Install

```bash
sudo ./install.sh --install-deps
```

The installer is idempotent and preserves existing files in
`/etc/pbs-protection`. If the generated reader token exists but its secret file
is lost, use:

```bash
sudo ./install.sh --rotate-reader-token
```

## Configure the NAS mount

The repository does not create the NFS mount blindly. Confirm that the mount is
persistent and points to the intended 2 TB USB-backed export:

```bash
findmnt /mnt/nas/pbs-mirror
touch /mnt/nas/pbs-mirror/.write-test && rm /mnt/nas/pbs-mirror/.write-test
```

Edit `/etc/pbs-protection/pbs-protection.env` if the mount or S3 path differs.

## Review expected groups

Discovery creates:

```text
/etc/pbs-protection/expected-backups.discovered.json
```

Copy it to the active policy, remove backups that are intentionally not required,
add anything missing, then set `reviewed` to `true`.

A group can be a string using the default age:

```json
"vm/431"
```

or an object with an override:

```json
{"group":"vm/431","max_age_hours":72}
```

## Validate and run

```bash
pbs-protection-cycle --check
pbs-protection-cycle --dry-run
systemctl start pbs-protection-cycle.service
journalctl -u pbs-protection-cycle.service -f
pbs-protection-status
```

Enable the timers only after a successful manual promotion:

```bash
systemctl enable --now pbs-protection-cycle.timer
systemctl enable --now pbs-protection-monthly-verify.timer
systemctl list-timers 'pbs-protection-*'
```
