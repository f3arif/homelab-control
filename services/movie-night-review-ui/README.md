# AFZ Movie Night private service

Canonical source: f3arif/homelab-control. This checkout preserves the current Seen, continuous-refill, genre and reserve fixes and adds the download workflow. It supersedes the older static-only PR #278 snapshot for future standalone service deployments.

Runtime: HP Envy; review backend on its private Unix socket. Dedicated entry: https://hpenvy.tailc9bb62.ts.net:8453/movie-night/. Connect Tailscale using the existing owner account and open the link; no billing password is needed. The loopback-only standalone gateway accepts only the exact owner identity supplied by Tailscale Serve, never billing cookies, and exposes no billing routes. Existing billing access on 8447 remains compatible. The stable internal principal and all saved choices/jobs remain shared.

The standalone gateway validates the actual external Host/Origin before normalizing write Origin to the backend's legacy configured origin; the backend still checks its CSRF token. It deliberately creates no cross-port browser session cookie. Private owner configuration is server-only, mode600 in a mode700 directory. Serve must remain private; never expose the loopback listener directly or add a blanket allowlist.

Access deployment: run the 16 standalone boundary tests and tests/standalone_qa.py from a clean tested checkout, then deploy_access.py apply on HP Envy. The script verifies tested source hashes, unused ports and owner identity, adds only afz-movie-night-access.service and the 8453 handler, and guards unrelated Serve configuration. Rollback from /home/coolyo/afz-stremio-secondhost-20260918/movie-night-access-20261023/deploy_access.py rollback refuses drift and leaves preferences/media/backend intact. Other historical download/UI rollback scripts do not manage this access service.

The page shows up to ten eligible suggestions, and both the server and browser allow 3–10 finalized picks. Refresh an already-open page after upgrading. Saved 3/4-pick selections remain valid; picking/finalizing still never starts a download.

The source-backed Android integration plan is [docs/AFZ-NUVIO-INTEGRATION.md](docs/AFZ-NUVIO-INTEGRATION.md). Nuvio currently uses its own local Movie Night picker; this change does not install an APK or claim synchronized draft picks.

Use Pick on 3 to 10 movies, Finalize, then Review server download. Lookup examines only completed, present files already in the owner's configured TorBox inventory. It does not add torrents or start media traffic. Exact title/year, file identity, 1080p, known codec, safety fields and size <=9GB are required; 3-5GB is ranked first. A background lookup prevents the gateway timeout. Missing sources are reported honestly.

Confirmation displays source filename and edition, IDs, codec, exact size, destination, measured free space, 50GiB reserve, remaining 100GB lifetime transfer budget and expiry. Only yes to that bound confirmation creates a durable job. Replays never dispatch twice. Files are downloaded to HP Envy /home/coolyo/afz-curated-media/Movies, NOT to a phone or the ZBook 8TB drive. Existing/partial files are preserved. No source substitution or automatic retries after interruption.

A one-worker queue verifies provider identity again, checks storage, writes an exclusive .part file, validates exact length, SHA256 and ffprobe video dimensions/codec, then publishes without overwrite. Downloaded, indexed/available and observed playback are separate states. Restarted in-progress work is failed/preserved; queued approvals are recovered. Job history and cancel survive browser reload. Cancellation never deletes completed files.

The isolated download index is served by authenticated Movie Night catalog/media routes; it does not claim Jellyfin/Radarr/Android Nuvio integration. An indexed file offers Save a copy to this device. Large media is streamed, including single ranges, through the owner gateway without buffering or exposing provider credentials/links. Streaming-source checks are not enabled by this download implementation.

Review-only mode remains default. --downloads is an explicit deployment setting. Production files and unit are backed up and hash guarded by deploy.py; rollback restores code and unit, not user DB choices or completed/partial media. Credentials are read lazily from the existing server-private addon configuration, never copied to Git.

Validation:
python -m pip install --target .test-deps -r requirements-test.txt
PYTHONPATH=src:tests:.test-deps python -m unittest discover -s tests -v
node --check src/screen.js
Gateway/browser QA uses disposable credentials, provider, movie data and a tiny generated video; it never uses real owner cookies or downloads a movie.
