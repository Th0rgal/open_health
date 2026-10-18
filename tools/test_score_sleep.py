import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

import score_sleep


class StageNightBridgeTests(unittest.TestCase):
    def test_hypnogram_comes_from_the_oura_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "oura"
            hyp = {"stages": [2, 2, 1, 4], "asleep_min": 1.5, "start_local": "23:10"}
            # the stand-in prints its arguments back so the call shape is checked too
            exe.write_text("#!/bin/sh\necho '" + json.dumps(hyp)[:-1] + ', "argv": "\'"$*"\'"}\'\n')
            exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
            offset = 2
            os.environ["OURA_BIN"] = str(exe)
            try:
                got = score_sleep.hypnogram_for_window("x.db", 10, 20, offset)
            finally:
                del os.environ["OURA_BIN"]
        self.assertEqual(got["stages"], [2, 2, 1, 4])
        self.assertEqual(got["argv"], f"--db x.db stage-night 10 20 --tz-offset {offset}")


if __name__ == "__main__":
    unittest.main()
