import importlib.util
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "icreadkit_doctor.py"
spec = importlib.util.spec_from_file_location("icreadkit_doctor", SCRIPT)
doctor = importlib.util.module_from_spec(spec)
sys.modules["icreadkit_doctor"] = doctor
spec.loader.exec_module(doctor)

GOOD_INFO = {
    "MinimumOSVersion": "17.0",
    "NFCReaderUsageDescription": "証明書の有効期限を確かめるために使います",
    "com.apple.developer.nfc.readersession.iso7816.select-identifiers": ["D392F000260100000001"],
}
GOOD_ENTITLEMENTS = {"com.apple.developer.nfc.readersession.formats": ["TAG"]}


def ids(findings):
    return [f.id for f in findings]


def elf(alignment: int) -> bytes:
    """A minimal 64-bit little-endian ELF header with one PT_LOAD program header."""
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<Q", header, 0x20, 64)          # e_phoff
    struct.pack_into("<HH", header, 0x36, 56, 1)      # e_phentsize, e_phnum
    program = bytearray(56)
    struct.pack_into("<I", program, 0, 1)             # PT_LOAD
    struct.pack_into("<Q", program, 48, alignment)    # p_align
    return bytes(header + program)


class IOSDoctorTests(unittest.TestCase):
    def test_a_correct_app_has_no_findings(self):
        self.assertEqual(doctor.check_ios(GOOD_INFO, GOOD_ENTITLEMENTS, ["a.framework", "b.framework"]), [])

    def test_each_common_mistake_is_named(self):
        cases = [
            ({**GOOD_INFO, "NFCReaderUsageDescription": " "}, GOOD_ENTITLEMENTS, [], "ICR-IOS-001"),
            ({**GOOD_INFO, "com.apple.developer.nfc.readersession.iso7816.select-identifiers": ["A0000002471001"]}, GOOD_ENTITLEMENTS, [], "ICR-IOS-002"),
            ({**GOOD_INFO, "MinimumOSVersion": "15.0"}, GOOD_ENTITLEMENTS, [], "ICR-IOS-003"),
            (GOOD_INFO, {"com.apple.developer.nfc.readersession.formats": ["NDEF"]}, [], "ICR-IOS-004"),
            (GOOD_INFO, {"com.apple.developer.nfc.readersession.formats": ["NDEF", "TAG"]}, [], "ICR-IOS-005"),
            (GOOD_INFO, GOOD_ENTITLEMENTS, ["com.vendor.lib", "com.vendor.lib"], "ICR-IOS-006"),
            (GOOD_INFO, None, [], "ICR-IOS-010"),
        ]
        for info, entitlements, embedded, expected in cases:
            with self.subTest(expected=expected):
                self.assertIn(expected, ids(doctor.check_ios(info, entitlements, embedded)))

    def test_ndef_is_fine_below_ios_13(self):
        old = {**GOOD_INFO, "MinimumOSVersion": "12.0"}
        found = ids(doctor.check_ios(old, {"com.apple.developer.nfc.readersession.formats": ["NDEF", "TAG"]}, []))
        self.assertNotIn("ICR-IOS-005", found)

    def test_an_app_bundle_on_disk_is_read_with_its_embedded_frameworks(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Host.app"
            for bundle, identifier in [("", "com.host"), ("Frameworks/ICReadKit.framework/", "com.kit"), ("PlugIns/Clip.appex/Frameworks/ICReadKit.framework/", "com.kit")]:
                (app / bundle).mkdir(parents=True, exist_ok=True)
                plist = {**GOOD_INFO, "CFBundleIdentifier": identifier} if not bundle else {"CFBundleIdentifier": identifier}
                (app / bundle / "Info.plist").write_bytes(plistlib.dumps(plist))
            entitlements = Path(folder) / "Host.entitlements"
            entitlements.write_bytes(plistlib.dumps(GOOD_ENTITLEMENTS))
            info, read_entitlements, embedded = doctor.read_ios_bundle(app, entitlements)
            self.assertEqual(sorted(embedded), ["com.kit", "com.kit"])
            self.assertEqual(ids(doctor.check_ios(info, read_entitlements, embedded)), ["ICR-IOS-006"])


class AndroidDoctorTests(unittest.TestCase):
    MANIFEST = '<manifest><uses-permission android:name="android.permission.NFC" /><uses-sdk android:minSdkVersion="26" /></manifest>'

    def test_elf_alignment_is_read_from_the_program_headers(self):
        self.assertEqual(doctor.elf_load_alignments(elf(0x4000)), [0x4000])
        self.assertEqual(doctor.elf_load_alignments(b"not an elf"), [])

    def test_a_4k_library_is_flagged_and_a_16k_one_is_not(self):
        self.assertIn("ICR-AND-001", ids(doctor.check_android({"lib/arm64-v8a/libcore.so": elf(0x1000)}, None, False)))
        self.assertEqual(doctor.check_android({"lib/arm64-v8a/libcore.so": elf(0x4000)}, None, False), [])
        # 32-bit ABIs are not part of the 16 KB requirement.
        self.assertEqual(doctor.check_android({"lib/armeabi-v7a/libcore.so": elf(0x1000)}, None, False), [])

    def test_manifest_and_keep_rule_mistakes_are_named(self):
        self.assertEqual(doctor.check_android({"proguard.txt": b"-keep class x"}, self.MANIFEST, True), [])
        self.assertIn("ICR-AND-002", ids(doctor.check_android({"proguard.txt": b""}, "<manifest/>", True)))
        self.assertIn("ICR-AND-003", ids(doctor.check_android({"proguard.txt": b""}, self.MANIFEST.replace('"26"', '"24"'), True)))
        required = self.MANIFEST.replace("</manifest>", '<uses-feature android:name="android.hardware.nfc" android:required="true" /></manifest>')
        self.assertIn("ICR-AND-004", ids(doctor.check_android({"proguard.txt": b""}, required, True)))
        self.assertIn("ICR-AND-005", ids(doctor.check_android({}, self.MANIFEST, True)))

    def test_an_aar_on_disk_is_read(self):
        with tempfile.TemporaryDirectory() as folder:
            aar = Path(folder) / "kit.aar"
            with zipfile.ZipFile(aar, "w") as archive:
                archive.writestr("AndroidManifest.xml", self.MANIFEST)
                archive.writestr("proguard.txt", "-keep class x")
                archive.writestr("jni/arm64-v8a/libcore.so", elf(0x1000))
            self.assertEqual(ids(doctor.check_android(*doctor.read_android_archive(aar))), ["ICR-AND-001"])


class CommandLineTests(unittest.TestCase):
    def test_the_exit_code_reflects_errors(self):
        with tempfile.TemporaryDirectory() as folder:
            aar = Path(folder) / "kit.aar"
            with zipfile.ZipFile(aar, "w") as archive:
                archive.writestr("AndroidManifest.xml", AndroidDoctorTests.MANIFEST)
                archive.writestr("proguard.txt", "-keep class x")
            self.assertEqual(doctor.main(["android", str(aar)]), 0)
            with zipfile.ZipFile(aar, "a") as archive:
                archive.writestr("lib/arm64-v8a/libold.so", elf(0x1000))
            self.assertEqual(doctor.main(["android", str(aar)]), 1)


if __name__ == "__main__":
    unittest.main()
