"""Automatic Movie Night refill should fill the visible shelf before it's almost empty.

Pure fixture tests: no provider queries, user records, downloads or production files.
"""
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from discovery_refill import DiscoveryRefill
import discovery_refill
from reviewed_refill import ReviewedRefill
from feedback import VISIBLE_MOVIES


class VisibleShelfTopUpTests(unittest.TestCase):
    def exercise_maintain(self, visible, expect_refill):
        with tempfile.TemporaryDirectory(prefix="movie-autotopup-fixture-") as state:
            source = DiscoveryRefill(state, discoverer=None)
            try:
                saved = {"genreRevision": 2, "retryAt": time.time() + 90, "outcome": "no-match"}
                with (
                    patch.object(source, "saved_status", return_value=saved),
                    patch.object(source.genre_settings, "read", return_value={"revision": 2}),
                    patch.object(source, "visible_count", return_value=visible),
                    patch.object(ReviewedRefill, "fulfill", return_value={"fulfilled": True, "added": 5}) as top_up,
                    patch.object(ReviewedRefill, "status", return_value={"available": 15}),
                    patch.object(discovery_refill, "atomic_json") as store,
                ):
                    source.maintain()
                    self.assertEqual(top_up.call_count, int(expect_refill))
                    self.assertIsNone(source.future)  # No remote metadata/provider activity.
                    self.assertEqual(store.call_count, int(expect_refill))
                    if expect_refill:
                        self.assertEqual(store.call_args.args[1]["outcome"], "refilled")
                        self.assertEqual(store.call_args.args[1]["added"], 5)
            finally:
                source.close()

    def test_automatically_promotes_reserve_when_six_eligible_remain(self):
        self.assertEqual(VISIBLE_MOVIES, 10)
        self.exercise_maintain(6, True)

    def test_automatically_promotes_reserve_when_nine_eligible_remain(self):
        self.exercise_maintain(VISIBLE_MOVIES - 1, True)

    def test_does_not_promote_more_when_full_shelf_already_visible(self):
        self.exercise_maintain(VISIBLE_MOVIES, False)

    def test_never_promotes_when_more_than_shelf_limit_are_already_eligible(self):
        self.exercise_maintain(VISIBLE_MOVIES + 2, False)


if __name__ == "__main__":
    unittest.main()
