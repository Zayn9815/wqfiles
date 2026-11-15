#!/usr/bin/env python3
import importlib.util
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ReleasePolicyTests(unittest.TestCase):
    def test_info_plist_declares_documented_ios_26_minimum(self):
        with (ROOT / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        self.assertEqual(info["MinimumOSVersion"], "26.0")

    def test_ipad_declares_all_orientations(self):
        with (ROOT / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        self.assertEqual(set(info["UISupportedInterfaceOrientations~ipad"]), {
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        })

    def test_signing_requests_app_group_but_not_signer_owned_identifier(self):
        with (ROOT / "entitlements.plist").open("rb") as plist_file:
            entitlements = plistlib.load(plist_file)
        self.assertNotIn("application-identifier", entitlements)
        self.assertEqual(
            entitlements["com.apple.security.application-groups"],
            ["group.cz.kolbi.wqfiles"],
        )

    def test_info_plist_declares_wq_glass_v4_identity(self):
        with (ROOT / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        self.assertEqual(info["CFBundleDisplayName"], "WQ Glass")
        self.assertEqual(info["CFBundleName"], "WQ Glass")
        self.assertEqual(info["CFBundleIdentifier"], "com.zayn.wqglass")
        self.assertEqual(info["CFBundleShortVersionString"], "4.0")

    def test_source_json_uses_zayn_repo_and_wq_glass_identity(self):
        import json
        source = json.loads((ROOT / "source.json").read_text(encoding="utf-8"))
        self.assertEqual(source["name"], "WQ Glass")
        self.assertEqual(source["website"], "https://github.com/Zayn9815/wqfiles")
        self.assertEqual(source["apps"][0]["bundleIdentifier"], "com.zayn.wqglass")
        self.assertEqual(source["apps"][0]["versions"][0]["version"], "4.0")
        self.assertIn("Zayn9815/wqfiles", source["apps"][0]["versions"][0]["downloadURL"])

    def test_catalog_policy_is_explicitly_26_0(self):
        # Load the updater and check its active constant, not source text.
        # The build's effective deployment target is checked by running
        # build.sh with fake tools (test_build.test_compiles_for_the_info_plist_minimum_os).
        spec = importlib.util.spec_from_file_location(
            "wq_update_source_policy", ROOT / "scripts" / "update_source.py")
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        self.assertEqual(module.MINIMUM_IOS_VERSION, "26.0")

if __name__ == "__main__":
    unittest.main()
