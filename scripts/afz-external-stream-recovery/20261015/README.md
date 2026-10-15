# AFZ expired external stream recovery

A cached Seinfeld S3E11 source repeatedly returned HTTP 404 from the resolver. The Node bridge keeps external tokens in memory for 30 minutes, while the Python catalog can retain source rows longer. Provider URL changes also change the token. Switching between VLC and Exo cannot repair that expired URL.

The deployed bridge was also using a stopped browser session for discovery, although an existing private provider configuration was already available on H3.

## Changes

- Keep a bounded, seven-day history of source identity (20,000 entries), excluding provider URLs and credentials.
- On token expiry, refresh once through the existing movie/episode filters and resolve only one exact filename/provider/source/resolution match. Compare exact sizes when available and preserve provider episode remapping.
- Serialize simultaneous recovery requests and reuse the recovered URL.
- Reject unknown or ambiguous episode sources, including invalid legacy cached URLs.
- Return a temporary 503 for bridge outages instead of misreporting every failure as an expired source.
- Use the existing private provider collection for external source discovery in both bridge copies. Account and ordering operations retain their prior behavior.

## Deployment

H3 rollout completed at 2026-10-15T00:37:18Z. Catalog SHA-256:
`26b74ce17942c4597a93cac4b4609db5dc6ce635d275c0ec6e27111b6d741b63`.

The installer builds isolated candidates from the current deployed source, preserving unrelated changes. It checks hashes immediately before writing, backs up files and logs, validates listener process identities, restarts only the affected services, and rolls back sources if acceptance fails. An initial rollout stopped at its command-line identity guard, restored the original sources and passed service acceptance. The whitespace comparison was corrected before the successful rollout.

Keep the package in a private H3 evidence directory before preparing/deploying. `prepare_candidates.py` builds candidates and a hash receipt; run both test scripts before `deploy_recovery.py`. Deployment is H3-specific, expects the existing private provider configuration, and refuses to reapply over an installed module. The optional selected-row fixture is local diagnostic input, never repository content.

## Validation

- 20 recovery tests passed: expiry, concurrent engines, persistent history, wrong episode/file/provider/size/resolution, ambiguity, remapping, unavailable bridge, and URL-free history.
- 36 existing episode-identity checks passed, including rejection of a bad legacy resolved URL before cache use.
- Both Node candidates passed syntax checks.
- Isolated discovery with browser debugging disabled returned 76 sources from three configured providers and retained the exact selected file.
- The original expired URL returned HTTP 206 and valid Matroska bytes twice through the local core and twice through the tailnet route. Total selected media size remained 2,573,211,753 bytes.
- Public-route start and seek range requests returned HTTP 206 with exact requested ranges.

These bounded network/media probes establish source recovery and range delivery. Physical playback on the reporting OnePlus has not been observed after deployment. No phone app was reinstalled, and no phone, network, account, or scheduled-task settings were changed.

Private source tokens, protected URLs, provider configuration, raw logs, browser storage and media samples remain off Git.
