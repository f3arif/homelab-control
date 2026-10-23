from dataclasses import replace
from pathlib import Path
import subprocess
import tempfile
import unittest
from adapters import validate_file
from test_downloads import probe


class MediaTests(unittest.TestCase):
    def test_real_ffprobe_and_hash_on_generated_clip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);path=root/'generated-fixture.mp4'
            subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=black:s=1920x1080:r=1','-t','1','-c:v','libx264','-pix_fmt','yuv420p','-y',str(path)],check=True,timeout=30)
            from test_movie_night import choice
            c=choice(codec='AVC',size=path.stat().st_size)
            proof=validate_file(path,c)
            self.assertTrue(proof['mediaProbePassed']);self.assertEqual(c.size,proof['actualSize']);self.assertEqual(64,len(proof['sha256']))
            with self.assertRaises(ValueError):validate_file(path,replace(c,codec='HEVC'))

    def test_cropped_full_hd_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'fixture.mkv';path.write_bytes(b'x')
            from test_movie_night import choice
            def cropped(p):return {'format':{'duration':'7200'},'streams':[{'codec_type':'video','codec_name':'h264','width':1920,'height':800}]}
            self.assertTrue(validate_file(path,choice(codec='AVC',size=1),cropped)['mediaProbePassed'])

    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'real').write_bytes(b'x');(root/'link').symlink_to(root/'real')
            from test_movie_night import choice
            with self.assertRaises(OSError):validate_file(root/'link',choice(codec='AVC',size=1),probe)


if __name__=='__main__':unittest.main(verbosity=2)
