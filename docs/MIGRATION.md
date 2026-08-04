# Migration from the old PBS jobs

The old server used independent timers for GC, NAS mirroring, S3 mirroring, drift
checking and reporting. Do not enable those units on `pbs-mini`.

## Safe cutover

1. Install this repository with timers disabled.
2. Configure and review the expected backup policy.
3. Run `pbs-protection-cycle --check`.
4. Run one manual complete promotion.
5. Confirm the NAS destination and S3 destination contain the new `pbs-sas`
   generation and current promotion markers.
6. Perform an enumeration or sample restore from the new PBS backup set.
7. Enable the new timers.
8. Disable the old independent timers where they exist:

```bash
systemctl disable --now \
  pbs-to-nas.timer \
  pbs-to-s3.timer \
  pbs-gc-guarded.timer \
  pbs-drift-check.timer \
  pbs-daily-report.timer
```

The installer can perform step 8 with `--disable-legacy`, but it is intentionally
not the default.

## Old NAS/S3 data

Delete the old PBS datastore copies only after the new promotion has remained
healthy for several days. Keep deletion as a separate, manually reviewed action;
do not put it into the recurring protection cycle.
