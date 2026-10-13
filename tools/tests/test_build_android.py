import json
from pathlib import Path
import tempfile
import unittest

from tools.build_android import summarize_tests


class TestProfileEvidence(unittest.TestCase):
    def summarize(self, events):
        with tempfile.TemporaryDirectory(prefix="android-profile-evidence-") as path:
            log = Path(path) / "tests.jsonl"
            log.write_text("\n".join("" if event is None else json.dumps(event)
                                     for event in events), encoding="ascii")
            return summarize_tests(log)

    def test_process_arrays_and_blank_lines_are_not_test_results(self):
        result = self.summarize([
            None, [{"event": "test.startedProcess", "pid": 42}],
            {"type": "testDone", "testID": 1, "result": "success"},
            {"type": "testDone", "testID": 2, "result": "success", "skipped": True},
            {"type": "testDone", "testID": 3, "result": "success", "hidden": True},
            {"type": "done", "success": True},
        ])
        self.assertEqual(result, {"passed": 1, "failed": 0, "skipped": 1})

    def test_failure_is_not_lost_among_process_events(self):
        with self.assertRaises(RuntimeError):
            self.summarize([
                [{"event": "test.startedProcess"}],
                {"type": "testDone", "testID": 1, "result": "failure"},
            ])

    def test_unsuccessful_loader_run_is_not_reported_as_passing(self):
        with self.assertRaises(RuntimeError):
            self.summarize([
                {"type": "testDone", "testID": 1, "result": "success"},
                {"type": "done", "success": False},
            ])

    def test_no_visible_results_cannot_be_called_passing(self):
        with self.assertRaises(RuntimeError):
            self.summarize([None, [], {"type": "done", "success": True}])


if __name__ == "__main__":
    unittest.main()
