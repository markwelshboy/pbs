# Design

## Protection objective

The NAS and S3 copies are promoted only from a locally healthy and verified PBS
backup set. A failed local backup, failed verification, storage error, failed NAS
sync or failed NAS check prevents S3 from being updated. Pruning and garbage
collection occur only after both downstream copies succeed.

## Storage generations

The 2 TB ext4 USB NAS disk and low-cost S3 target each hold one current datastore
generation. No datastore history or S3 object versioning is assumed. Small JSON
promotion markers are maintained outside the datastore mirror.

## Namespaces

Expected groups are tracked inside the four source namespaces:

- `r630`
- `nuc-pve`
- `beelink-pve`
- `mini-pve`

Each namespace can contain `vm`, `ct` and `host` groups. The host-configuration
orchestrator remains on `r630`; this project only checks that those host snapshots
arrived in PBS.

## Verification

`pbs-sas-promotion` skips verification that is still current and rechecks it after
30 days. The systemd promotion cycle runs the job and then requires the latest
snapshot of every expected group to report `OK`.

`pbs-sas-monthly-full` does not ignore previously verified snapshots and is run by
a separate monthly systemd timer under the same lock.

## Consistency

Before mirroring, the cycle waits for relevant PBS tasks to become idle and sets
the datastore to read-only maintenance mode. The mode is cleared by an exit trap,
including failure paths.

## Failure semantics

- No success marker is advanced before NAS and S3 complete.
- NAS/S3 sync uses `--delete-after`.
- S3 is sourced from the checked NAS mirror, not directly from the live datastore.
- A post-promotion prune/GC failure reports an error but does not invalidate the
  already completed offsite promotion.
