# PBS verified promotion pipeline

A fail-closed protection pipeline for the `pbs-mini` Proxmox Backup Server.

It replaces independent NAS, S3, verification and garbage-collection timers with
one ordered cycle:

1. Validate the PBS datastore mount, SMART state and kernel logs.
2. Require a recent snapshot for every explicitly listed VM, CT and host group.
3. Run the PBS promotion verification job.
4. Require the latest expected snapshots to report verification state `OK`.
5. Enter PBS read-only maintenance mode.
6. Mirror the datastore to the NAS and check the result.
7. Clear maintenance mode.
8. Mirror the promoted NAS generation to low-cost, unversioned S3 and check it.
9. Write promotion markers and advance `last-success.json`.
10. Only then run configured prune jobs and weekly garbage collection.

Any failure before step 9 leaves the previous NAS/S3 generation untouched as far
as rclone can safely do so. `rclone sync --delete-after` delays destination
deletions until transfers complete, and rclone suppresses deletions when errors
occur. This is not immutable/versioned storage, but it is a deliberate low-cost
promotion model.

## Repository safety

This repository is public. It contains no credentials. Runtime configuration and
secrets live only on `pbs-mini` under `/etc/pbs-protection` and existing root-only
rclone/Telegram locations.

## Install from `pbs-mini`

```bash
git clone https://github.com/markwelshboy/pbs.git
cd pbs
sudo ./install.sh --install-deps
```

The installer creates a dedicated `pbs-protection@pbs!reader` audit token, two
unscheduled PBS verification jobs, scripts, systemd units and review-required
configuration. It leaves timers disabled.

## Deploy from ddraigPC

```bash
git clone https://github.com/markwelshboy/pbs.git
cd pbs
./deploy.sh pbs-mini-direct --install-deps
```

## First rollout

```bash
sudoedit /etc/pbs-protection/pbs-protection.env
sudo cat /etc/pbs-protection/expected-backups.discovered.json
sudo cp /etc/pbs-protection/expected-backups.discovered.json \
  /etc/pbs-protection/expected-backups.json
sudoedit /etc/pbs-protection/expected-backups.json
# Set "reviewed": true only after checking every required group.

sudo pbs-protection-cycle --check
sudo pbs-protection-cycle --dry-run
sudo systemctl start pbs-protection-cycle.service
sudo pbs-protection-status

sudo systemctl enable --now pbs-protection-cycle.timer
sudo systemctl enable --now pbs-protection-monthly-verify.timer
```

Do not disable or delete the old jobs until the first new NAS and S3 promotion has
completed and been inspected. See `docs/MIGRATION.md`.
