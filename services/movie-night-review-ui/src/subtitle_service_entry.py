"""Opt-in Movie Night subtitle entrypoint; original service and auth remain owner.

Use only during a coordinated rollout. This file does not edit a unit, open a
new listener, turn on deletion or start extraction. All original service args
are forwarded unchanged; only --subtitle-cache is consumed here.
"""
import argparse
from functools import wraps
import inspect
from pathlib import Path
import sys

from server_subtitles import SubtitleCache, attach_subtitle_routes


def add_subtitles_to_factory(original, *, cache_dir, principal, ffmpeg, ffprobe):
    signature = inspect.signature(original)
    if not {'state', 'downloads'}.issubset(signature.parameters):
        raise ValueError('Unexpected service factory; reconcile before rollout')
    if not isinstance(principal, str) or not principal:
        raise ValueError('Existing private principal required')

    @wraps(original)
    def build(*args, **kwargs):
        bound = signature.bind(*args, **kwargs)
        bound.apply_defaults()
        if not bound.arguments['downloads']:
            raise ValueError('Subtitles need the existing indexed-download boundary')
        app, controller = original(*args, **kwargs)
        try:
            if controller.index is None:
                raise ValueError('Existing media index required')
            cache = SubtitleCache(controller.index, cache_dir, ffmpeg=ffmpeg, ffprobe=ffprobe)
            # Same trusted internal principal as review_service. The original
            # main() continues to wrap the app in RelayAuth before TCP serving.
            attach_subtitle_routes(app, cache, authorize=lambda request:
                principal if request.headers.getlist('x-afz-review-principal') == [principal] else None)
            app.state.movie_night_subtitles = cache
            return app, controller
        except Exception:
            controller.close()
            raise
    return build


def main(argv=None):
    import review_service
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--subtitle-cache', required=True)
    options, remaining = parser.parse_known_args(sys.argv[1:] if argv is None else argv)
    runtime = Path(sys.executable).absolute().parent
    original, old_argv = review_service.build_app, sys.argv
    review_service.build_app = add_subtitles_to_factory(original,
        cache_dir=options.subtitle_cache, principal=review_service.PRINCIPAL,
        ffmpeg=runtime/'ffmpeg', ffprobe=runtime/'ffprobe')
    try:
        sys.argv = [str(Path(review_service.__file__)), *remaining]
        review_service.main()  # Original socket/relay-secret/shutdown handling.
    finally:
        review_service.build_app = original
        sys.argv = old_argv


if __name__ == '__main__':
    main()
