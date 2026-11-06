"""Check GPU boot argument normalization without modifying host boot files."""
import os
from pathlib import Path
import subprocess
import runpy
import unittest

CONFIG = Path(__file__).resolve().parents[1] / "ansible/roles/gpu_blacklist/files/gpu-blacklist.cfg"


def normalize(linux="", default="", repeats=1):
    env = dict(os.environ, GRUB_CMDLINE_LINUX=linux, GRUB_CMDLINE_LINUX_DEFAULT=default)
    command = '. "$1"; ' * repeats
    command += 'printf "%s\\n%s\\n" "$GRUB_CMDLINE_LINUX" "$GRUB_CMDLINE_LINUX_DEFAULT"'
    result = subprocess.run(["/bin/sh", "-c", command, "test", str(CONFIG)],
                            env=env, text=True, capture_output=True, check=True)
    return result.stdout.splitlines()


class BootArgumentsTest(unittest.TestCase):
    def assert_policy(self, result):
        linux, default = result
        tokens = (linux + " " + default).split()
        blacklists = [t.split("=", 1)[1] for t in tokens if t.startswith("modprobe.blacklist=")]
        self.assertEqual(len(blacklists), 1)
        modules = blacklists[0].split(",")
        self.assertIn("nouveau", modules)
        self.assertIn("amdgpu", modules)
        self.assertEqual(len(modules), len(set(modules)))
        self.assertEqual(tokens.count("nouveau.modeset=0"), 1)
        self.assertFalse(any(t.startswith("nouveau.modeset=") and t != "nouveau.modeset=0" for t in tokens))
        return modules

    def test_empty(self):
        result = normalize()
        self.assert_policy(result)
        self.assertEqual(result[1], "")

    def test_existing_options_and_blacklists(self):
        result = normalize("root=UUID=abc console=ttyS0 modprobe.blacklist=foo,nouveau nouveau.modeset=1",
                           "quiet splash modprobe.blacklist=bar,amdgpu,foo nouveau.modeset=1")
        self.assertEqual(set(self.assert_policy(result)), {"foo", "bar", "nouveau", "amdgpu"})
        self.assertIn("root=UUID=abc", result[0].split())
        self.assertIn("console=ttyS0", result[0].split())
        self.assertEqual(result[1].split(), ["quiet", "splash"])

    def test_repeated_application(self):
        linux = "ro modprobe.blacklist=nouveau,nouveau modprobe.blacklist=amdgpu,foo nouveau.modeset=0"
        first = normalize(linux, "quiet")
        self.assert_policy(first)
        self.assertEqual(first, normalize(linux, "quiet", repeats=3))
        self.assertEqual(first, normalize(*first))

    def test_shell_metacharacters_remain_data(self):
        result = normalize("root=/dev/mapper/root audit=1", "quiet $literal *.img")
        self.assert_policy(result)
        self.assertEqual(result[1].split(), ["quiet", "$literal", "*.img"])


class GeneratedEntriesTest(unittest.TestCase):
    def setUp(self):
        self.verify = runpy.run_path(str(CONFIG.with_name("verify-args.py")))["verify"]

    def test_grub_and_grubby_entries(self):
        args = "ro modprobe.blacklist=nouveau,amdgpu,foo nouveau.modeset=0"
        self.assertEqual(self.verify([" linux /vmlinuz " + args, " linuxefi /vmlinuz " + args]), 2)
        self.assertEqual(self.verify(['index=0', 'args="' + args + '"'], grubby=True), 1)

    def test_reject_missing_conflicting_or_partial_entries(self):
        good = "linux /vmlinuz modprobe.blacklist=nouveau,amdgpu nouveau.modeset=0"
        for bad in ("linux /vmlinuz quiet", good + " nouveau.modeset=1",
                    good.replace("nouveau,amdgpu", "nouveau")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.verify([good, bad])
        with self.assertRaises(ValueError):
            self.verify(["# No boot entries"])


if __name__ == "__main__":
    unittest.main()
