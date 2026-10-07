# Additional Pi and HP backups on the H3 media drive

The existing HP Nextcloud backup created local database exports but could not
reach its H3 SFTP destination from Docker's bridge network. A read-only test
using the same credentials and image succeeded with host networking.

`patch_nextcloud.py` makes the bounded transport repair and inserts
`guard_volume.py` before backup work and before publishing the success marker.
The guard uses the existing SSH identity with strict host-key verification to
query Windows volume metadata, then requires the configured drive letter,
volume label, stable volume GUID and free-space reserve. An unavailable or
different drive causes failure. Existing backup paths and retention remain
under the established script's control.

Runtime profiles stay private on the deployment host. Public code and tests
contain no deployment addresses, MACs, credential values or user files. The
existing SSH private keys are used in place and are not copied to another host.

## Checks

```sh
python3 -m unittest -v test_guard_volume
```

The eight checks cover the exact target identity, space boundary, unavailable
SSH, malformed responses, strict host-key verification, bounded timeouts,
source-anchor rejection and preservation of the existing retention commands.

## Deployment

Verify the inspected source SHA-256, save original bytes and modes, stage the
new source, check shell syntax, and run the volume guard before replacement.
If a previous transfer is stuck in a bridge-network client, stop only that
identified backup client and allow the existing wrapper to release its lock.
Start the repaired wrapper, then verify fresh destination data and its success
marker. Preserve the existing backup schedule. Rollback restores the saved
wrapper and its mode.
