"""Explicit subtitle gateway launcher; original owner config/CLI/auth retained.

A coordinated rollout changes only the entrypoint, not the existing gateway
source, ranking, deletion routes, origin, owner identity or listening port.
"""
from pathlib import Path
import sys

import standalone_server
from nuvio_subtitle_bridge import enable_subtitles


def gateway_class_with_subtitles(base):
    class SubtitleMovieNightServer(base):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            try:
                enable_subtitles(self)
            except Exception:
                self.server_close()
                raise
    return SubtitleMovieNightServer


def main(argv=None):
    original, old_argv = standalone_server.MovieNightServer, sys.argv
    standalone_server.MovieNightServer = gateway_class_with_subtitles(original)
    try:
        if argv is not None:
            sys.argv = [str(Path(standalone_server.__file__)), *argv]
        standalone_server.main()
    finally:
        standalone_server.MovieNightServer = original
        sys.argv = old_argv


if __name__ == '__main__':
    main()
