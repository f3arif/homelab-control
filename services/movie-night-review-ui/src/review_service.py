"""Standalone review service with bounded public metadata discovery; no media acquisition."""
import argparse
import json
import os
from pathlib import Path
import socket
import stat
from webapp import Controller, create_app
from reviewed_refill import ReviewedRefill
from movie_presentation import with_cached_info

PRINCIPAL = 'billing-owner'
GET_PATHS = frozenset(('/movie-night', '/movie-night/', '/movie-night/screen.js', '/movie-night/screen.css', '/movie-night/api/shortlist', '/movie-night/posters/{imdb}.img'))
POST_PATHS = frozenset(('/movie-night/api/feedback', '/movie-night/api/finalize'))

def build_app(state, origin, discovery=None, downloads=False, provider=None, media_root=None):
    state = Path(state)
    def payload():
        try:
            raw = (state / 'reviewed-shortlist.json').read_bytes()
            if len(raw) > 262144: return {}
            result = json.loads(raw)
            return with_cached_info(result,state/'movie-metadata.json') if isinstance(result, dict) else {}
        except (OSError, ValueError): return {}
    def forbidden(*args, **kwargs):
        raise RuntimeError('Acquisition unavailable in review service')
    refill=ReviewedRefill(state)
    if discovery is not None:
        from discovery_refill import DiscoveryRefill
        refill=DiscoveryRefill(state,discovery)
    controller = Controller(state / 'preferences.sqlite3', forbidden, None, None, None, forbidden,
                            enabled=False, review_enabled=True, shortlist_payload=payload, refill_provider=refill)
    if downloads:
        import shutil
        from adapters import WorkerAdapter, ProviderInventory, MediaIndex
        from download_provider import ConfiguredProvider, InventoryChoices
        import worker_candidate as worker
        root=worker.safe_directory(media_root or '/home/coolyo/afz-curated-media',create=True)
        worker.safe_directory(root/'Movies',create=True)
        transfer_state=worker.safe_directory(state/'transfers',create=True)
        provider=provider or ConfiguredProvider()
        index=MediaIndex(state/'download-index.sqlite3',root)
        free=lambda:shutil.disk_usage(root).free
        adapter=WorkerAdapter(state/'preferences.sqlite3',root,transfer_state,provider,index,enabled=True,
                              free=lambda _root:free(),verify_route=lambda imdb,size:verify_local_route(state,imdb,size))
        controller.choices=InventoryChoices(provider,payload)
        controller.inventory=ProviderInventory(provider);controller.worker=adapter;controller.index=index
        controller.free=free;controller.enabled=True
        controller.recover_jobs()
    app = create_app(controller, authorize=lambda r: PRINCIPAL if r.headers.get('x-afz-review-principal') == PRINCIPAL else None,
                     allowed_origin=origin)
    app.router.routes = [r for r in app.routes if
                        (r.path in GET_PATHS and r.methods == {'GET'}) or
                        (downloads and r.path in DOWNLOAD_GET and r.methods == {'GET'}) or
                        (downloads and r.path == '/movie-night/media/{imdb}' and r.methods == {'GET','HEAD'}) or
                        (r.path in POST_PATHS | (DOWNLOAD_POST if downloads else set()) and r.methods == {'POST'})]
    app.router.redirect_slashes = False
    return app, controller

def main():
    import uvicorn
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    parser.add_argument('--origin', required=True)
    parser.add_argument('--downloads', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    state = Path(args.state)
    run = state / 'run'
    for directory in (state, run):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError('Private owned state directories required')
    endpoint = run / 'review.sock'
    if endpoint.exists() or endpoint.is_symlink():
        info = endpoint.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError('Unexpected socket path')
        probe = socket.socket(socket.AF_UNIX)
        try:
            probe.connect(str(endpoint))
        except ConnectionRefusedError:
            endpoint.unlink()  # own stale socket only
        else:
            raise RuntimeError('Review socket already active')
        finally:
            probe.close()
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(endpoint))
    os.chmod(endpoint, 0o600)
    listener.listen(128)
    from metadata_discovery import CinemetaDiscovery
    app, controller = build_app(state, args.origin, discovery=CinemetaDiscovery(), downloads=args.downloads)
    try:
        uvicorn.Server(uvicorn.Config(app, access_log=False, log_level='warning')).run(sockets=[listener])
    finally:
        controller.close()
        listener.close()



DOWNLOAD_GET=frozenset(('/movie-night/api/lookup/{pid}','/movie-night/api/status/{pid}','/movie-night/api/downloads','/movie-night/catalog/movie/downloaded.json'))
DOWNLOAD_POST=frozenset(('/movie-night/api/propose','/movie-night/api/approve','/movie-night/api/cancel'))

def verify_local_route(state,imdb,size):
    from movie_transport import UnixConnection
    connection=UnixConnection(state/'run/review.sock')
    try:
        connection.request('HEAD','/movie-night/media/'+imdb,headers={'X-AFZ-Review-Principal':PRINCIPAL})
        response=connection.getresponse()
        return response.status==200 and int(response.getheader('Content-Length','-1'))==size
    except Exception:return False
    finally:connection.close()

if __name__ == '__main__': main()
