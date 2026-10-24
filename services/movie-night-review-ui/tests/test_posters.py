"""Exercise the production network path, including its installed dependency."""
import concurrent.futures
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import requests
from movie_posters import MAX_BYTES, PosterCache

JPEG = b'\xff\xd8\xff' + b'fixture-image' * 3 + b'\xff\xd9'
IMDB = 'tt12345'


class Response:
    def __init__(self, data=JPEG, status=200, mime='image/jpeg', length=None):
        self.data, self.status_code, self.read = data, status, False
        self.headers = {'Content-Type': mime}
        if length is not None:
            self.headers['Content-Length'] = str(length)

    def __enter__(self): return self
    def __exit__(self, *args): pass

    def iter_content(self, size):
        self.read = True
        for offset in range(0, len(self.data), size):
            yield self.data[offset:offset + size]


class Posters(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name) / 'posters'
        self.cache = PosterCache(self.directory)

    def test_default_client_fetches_and_then_uses_cache(self):
        with patch('requests.get', return_value=Response()) as get:
            self.assertEqual(self.cache.get(IMDB), JPEG)
            self.assertEqual(self.cache.get(IMDB), JPEG)
        get.assert_called_once()
        args, kwargs = get.call_args
        self.assertEqual(args, ('https://images.metahub.space/poster/small/tt12345/img',))
        self.assertFalse(kwargs['allow_redirects'])
        self.assertTrue(kwargs['stream'])
        self.assertLessEqual(sum(kwargs['timeout']), 3)
        self.assertEqual((self.directory / (IMDB + '.img')).stat().st_mode & 0o777, 0o600)

    def test_invalid_identifiers_never_fetch(self):
        with patch('requests.get') as get:
            for value in ('../file', 'https://example.test', 'tt12345/extra', 'tt12345?url=x', None):
                self.assertIsNone(self.cache.get(value))
        get.assert_not_called()

    def test_redirects_errors_and_wrong_content_are_not_cached(self):
        for response in (Response(status=302), Response(status=404), Response(mime='text/html'), Response(data=b'<html>not a poster</html>')):
            with self.subTest(status=response.status_code, mime=response.headers['Content-Type']):
                with patch('requests.get', return_value=response):
                    self.assertIsNone(self.cache.get(IMDB))
                self.assertFalse((self.directory / (IMDB + '.img')).exists())

    def test_known_oversize_is_refused_before_read(self):
        response = Response(length=MAX_BYTES + 1)
        with patch('requests.get', return_value=response):
            self.assertIsNone(self.cache.get(IMDB))
        self.assertFalse(response.read)

    def test_unknown_length_cannot_exceed_cap(self):
        with patch('requests.get', return_value=Response(data=b'\xff\xd8\xff' + b'x' * MAX_BYTES + b'\xff\xd9')):
            self.assertIsNone(self.cache.get(IMDB))
        self.assertFalse((self.directory / (IMDB + '.img')).exists())

    def test_timeout_can_recover_on_next_request(self):
        with patch('requests.get', side_effect=requests.Timeout('fixture timeout')):
            self.assertIsNone(self.cache.get(IMDB))
        with patch('requests.get', return_value=Response()):
            self.assertEqual(self.cache.get(IMDB), JPEG)

    def test_elapsed_download_deadline_is_enforced(self):
        with patch('requests.get', return_value=Response()), patch('movie_posters.time.monotonic', side_effect=[0, 0, 0, 4]):
            self.assertIsNone(self.cache.get(IMDB))

    def test_concurrent_duplicate_cards_fetch_once(self):
        def fetch(*args, **kwargs):
            time.sleep(.04)
            return Response()
        with patch('requests.get', side_effect=fetch) as get:
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                self.assertEqual(list(pool.map(self.cache.get, [IMDB] * 4)), [JPEG] * 4)
        self.assertEqual(get.call_count, 1)

    def test_symlink_cache_is_refused(self):
        self.directory.mkdir(mode=0o700)
        target = Path(self.tmp.name) / 'other'
        target.write_bytes(JPEG)
        (self.directory / (IMDB + '.img')).symlink_to(target)
        with patch('requests.get') as get:
            self.assertIsNone(self.cache.get(IMDB))
        get.assert_not_called()


if __name__ == '__main__': unittest.main()
