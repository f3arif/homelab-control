"""Private review service with bounded discovery and optional confirmed server downloads."""
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

def build_app(state, origin, discovery=None, downloads=False, provider=None, media_root=None, auto_downloads=False, volume=None, server_delete=False):
    if auto_downloads and not downloads:raise ValueError('Automatic downloads require --downloads')
    if server_delete and not downloads:raise ValueError('Server deletion requires --downloads')
    state = Path(state)
    def payload():
        try:
            raw = (state / 'reviewed-shortlist.json').read_bytes()
            if len(raw) > 262144: return {}
            result = json.loads(raw)
            if not isinstance(result,dict):return {}
            # Re-enabled retained titles must also be available to exact source lookup.
            rows=result.get('movies',[])+result.get('retainedIneligibleSelections',[])+result.get('genreFilteredMovies',[])
            unique={}
            for row in rows:
                if isinstance(row,dict) and isinstance(row.get('id'),str):unique.setdefault(row['id'],row)
            result=dict(result,movies=list(unique.values()))
            return with_cached_info(result,state/'movie-metadata.json')
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
        if media_root is None:
            from storage_volume import MediaVolume
            volume = volume or MediaVolume()
            root = volume.root  # no creation or fallback when the disk is unavailable
        else:
            root=worker.safe_directory(media_root,create=True)
            worker.safe_directory(root/'Movies',create=True)
        transfer_state=worker.safe_directory(state/'transfers',create=True)
        provider=provider or ConfiguredProvider()
        index=MediaIndex(state/'download-index.sqlite3',root,storage_guard=volume.check if volume else None)
        free=volume.check if volume else lambda:shutil.disk_usage(root).free
        adapter=WorkerAdapter(state/'preferences.sqlite3',root,transfer_state,provider,index,enabled=True,
                              free=lambda _root:free(),storage_guard=volume.check if volume else None,verify_route=lambda imdb,size:verify_local_route(state,imdb,size))
        controller.choices=InventoryChoices(provider,controller.shortlist_payload)
        controller.inventory=ProviderInventory(provider);controller.worker=adapter;controller.index=index
        controller.free=free;controller.enabled=True
        if server_delete:
            from server_file_delete import ServerFileDeletion
            controller.delete_service=ServerFileDeletion(index,controller.db,clock=controller.clock)
        controller.recover_jobs()
        if auto_downloads:
            from cached_sources import CachedSources
            controller.enable_auto_downloads(CachedSources(provider,controller.shortlist_payload).acquire)
    app = create_app(controller, authorize=lambda r: PRINCIPAL if r.headers.get('x-afz-review-principal') == PRINCIPAL else None,
                     allowed_origin=origin)
    app.router.routes = [r for r in app.routes if
                        (r.path in GET_PATHS and r.methods == {'GET'}) or
                        (downloads and r.path in DOWNLOAD_GET and r.methods == {'GET'}) or
                        (server_delete and r.path in DELETE_GET and r.methods == {'GET'}) or
                        (downloads and r.path == '/movie-night/media/{imdb}' and r.methods == {'GET','HEAD'}) or
                        (r.path in POST_PATHS | (DOWNLOAD_POST if downloads else set()) | (DELETE_POST if server_delete else set()) and r.methods == {'POST'})]
    app.router.redirect_slashes = False
    return app, controller

def main():
    import uvicorn
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    parser.add_argument('--origin', required=True)
    parser.add_argument('--downloads', action='store_true')
    parser.add_argument('--auto-downloads', action='store_true')
    parser.add_argument('--server-delete', action='store_true', help='Explicitly activate owner-confirmed server deletion after approval')
    parser.add_argument('--relay-secret')
    parser.add_argument('--listen', choices=['100.77.196.70'])
    parser.add_argument('--port', type=int, default=8797, choices=[8797])
    args = parser.parse_args()
    if bool(args.listen) != bool(args.relay_secret):parser.error('Listen and relay secret must be configured together')
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
    app, controller = build_app(state, args.origin, discovery=CinemetaDiscovery(), downloads=args.downloads, auto_downloads=args.auto_downloads, server_delete=args.server_delete)
    listeners=[listener]
    if args.listen:
        from private_relay import RelayAuth, read_secret
        app=RelayAuth(app,read_secret(args.relay_secret),unix_path=endpoint)
        tcp=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
        tcp.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        tcp.bind((args.listen,args.port));tcp.listen(128);listeners.append(tcp)
    try:
        uvicorn.Server(uvicorn.Config(app, access_log=False, log_level='warning',proxy_headers=False)).run(sockets=listeners)
    finally:
        controller.close()
        for s in listeners:s.close()



DOWNLOAD_GET=frozenset(('/movie-night/api/lookup/{pid}','/movie-night/api/status/{pid}',
    '/movie-night/api/downloads','/movie-night/catalog/movie/downloaded.json'))
DOWNLOAD_POST=frozenset(('/movie-night/api/propose','/movie-night/api/approve','/movie-night/api/cancel'))
DELETE_GET=frozenset(('/movie-night/api/delete-server/{imdb}',))
DELETE_POST=frozenset(('/movie-night/api/delete-server',))

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

