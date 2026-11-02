import tempfile
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from inspect_guest_hyperv_kvp import probe_paths

class GuestKvpDiscoveryTests(unittest.TestCase):
    def test_read_only_detection(self):
        with tempfile.TemporaryDirectory() as root:
            a = Path(root) / 'pool'
            b = Path(root) / 'pub'
            a.touch()
            b.touch()
            result = probe_paths((a,), b)
            self.assertTrue(result['guestPoolAccessible'])
            self.assertTrue(result['hostPublicKeyPresent'])
            self.assertFalse(result['poolModified'])
            self.assertFalse(result['hostPrivateKeyAccessed'])

    def test_missing_or_multiple_pools(self):
        with tempfile.TemporaryDirectory() as root:
            a = Path(root) / 'a'
            b = Path(root) / 'b'
            self.assertFalse(probe_paths((a,b),a)['guestPoolAccessible'])
            a.touch()
            b.touch()
            self.assertFalse(probe_paths((a,b),a)['guestPoolAccessible'])

if __name__ == '__main__':
    unittest.main()
