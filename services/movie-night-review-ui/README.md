# AFZ Movie Night private service

Canonical source: f3arif/homelab-control. This checkout preserves the current Seen, continuous-refill, genre and reserve fixes and adds the download workflow. It supersedes the older static-only PR #278 snapshot for future standalone service deployments.

Runtime: HP Envy; review backend on its private Unix socket, billing gateway provides existing owner session, Host/Origin and CSRF checks. No public listener or new login is added.

Use Pick on 3 or 4 movies, Finalize, then Review server download. Lookup examines only completed, present files already in the owner's configured TorBox inventory. It does not add torrents or start media traffic. Exact title/year, file identity, 1080p, known codec, safety fields and size <=9GB are required; 3-5GB is ranked first. A background lookup prevents the gateway timeout. Missing sources are reported honestly.

Confirmation displays source filename and edition, IDs, codec, exact size, destination, measured free space, 50GiB reserve, remaining 100GB lifetime transfer budget and expiry. Only yes to that bound confirmation creates a durable job. Replays never dispatch twice. Files are downloaded to HP Envy /home/coolyo/afz-curated-media/Movies, NOT to a phone or the ZBook 8TB drive. Existing/partial files are preserved. No source substitution or automatic retries after interruption.

A one-worker queue verifies provider identity again, checks storage, writes an exclusive .part file, validates exact length, SHA256 and ffprobe video dimensions/codec, then publishes without overwrite. Downloaded, indexed/available and observed playback are separate states. Restarted in-progress work is failed/preserved; queued approvals are recovered. Job history and cancel survive browser reload. Cancellation never deletes completed files.

The isolated download index is served by authenticated Movie Night catalog/media routes; it does not claim Jellyfin/Radarr/Android Nuvio integration. An indexed file offers Save a copy to this device. Large media is streamed, including single ranges, through the owner gateway without buffering or exposing provider credentials/links. Streaming-source checks are not enabled by this download implementation.

Review-only mode remains default. --downloads is an explicit deployment setting. Production files and unit are backed up and hash guarded by deploy.py; rollback restores code and unit, not user DB choices or completed/partial media. Credentials are read lazily from the existing server-private addon configuration, never copied to Git.

Validation:
PYTHONPATH=src:tests python -m unittest discover -s tests -v
node --check src/screen.js
Gateway/browser QA uses disposable credentials, provider, movie data and a tiny generated video; it never uses real owner cookies or downloads a movie.
