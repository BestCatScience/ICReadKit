import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import review_checks  # noqa: E402


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = load("guard_edit", SCRIPTS / "hooks" / "guard_edit.py")
stop = load("stop_gate", SCRIPTS / "hooks" / "stop_gate.py")
APDU = 'enum I { static let allowed: Set<UInt8> = [select, readBinary] }\n'


class ReviewCheckTests(unittest.TestCase):
    def test_the_repository_passes(self) -> None:
        self.assertEqual(review_checks.problems(), [])

    def test_each_finding_fires(self) -> None:
        cases = {
            'let url = "https://example.com/upload"': "URL",
            "print(certificate)": "ログ",
            'let log = Logger(subsystem: "x", category: "y")': "ログ",
            'UserDefaults.standard.set(data, forKey: "c")': "保存",
            "let task = URLSession.shared.dataTask(with: request)": "通信",
            "CommandAPDU(ins: 0x20, p1: 0, p2: 0x80)": "暗証番号",
            "static func verify(pin: Data) -> CommandAPDU": "暗証番号",
        }
        for line, reason in cases.items():
            with self.subTest(line=line):
                found = review_checks.kit_problems("Sources/ICReadKit/X.swift", line + "\n")
                self.assertEqual(len(found), 1, found)
                self.assertIn(reason, found[0])

    def test_comments_and_ordinary_code_stay_quiet(self) -> None:
        text = "/// Never sends VERIFY; see https://example.com\nlet length = min(256, rest)\n"
        self.assertEqual(review_checks.kit_problems("Sources/ICReadKit/X.swift", text), [])

    def test_widening_the_allowed_instructions_fires(self) -> None:
        self.assertEqual(review_checks.kit_problems("Sources/ICReadKit/APDU.swift", APDU), [])
        widened = APDU.replace("readBinary]", "readBinary, verify]")
        self.assertTrue(review_checks.kit_problems("Sources/ICReadKit/APDU.swift", widened))

    def test_a_new_dependency_fires(self) -> None:
        self.assertEqual(review_checks.manifest_problems("let p = Package(name: \"K\")", "name: K\n"), [])
        self.assertTrue(review_checks.manifest_problems('dependencies: [.package(url: "x", from: "1.0.0")]', ""))
        self.assertTrue(review_checks.manifest_problems("", "packages:\n  Lib:\n    url: x\n"))


class AndroidReviewCheckTests(unittest.TestCase):
    def test_each_android_finding_fires(self) -> None:
        cases = {
            'String url = "https://example.com/upload";': "URL",
            'Log.d("ICReadKit", certificate.toString());': "ログ",
            "System.out.println(certificate);": "ログ",
            'SharedPreferences prefs = context.getSharedPreferences("c", 0);': "保存",
            "HttpURLConnection connection = (HttpURLConnection) url.openConnection();": "通信",
            "new CommandApdu((byte) 0x20, 0x00, 0x80, pin, -1)": "暗証番号",
            "static CommandApdu verify(byte[] pin) {": "暗証番号",
        }
        for line, reason in cases.items():
            with self.subTest(line=line):
                found = review_checks.android_kit_problems("android/X.java", line + "\n")
                self.assertEqual(len(found), 1, found)
                self.assertIn(reason, found[0])

    def test_javadoc_and_ordinary_code_stay_quiet(self) -> None:
        text = "/** Never sends VERIFY; see https://example.com */\n * https://example.com\nint length = Math.min(256, rest);\n"
        self.assertEqual(review_checks.android_kit_problems("android/X.java", text), [])

    def test_a_runtime_dependency_in_the_kit_fires_and_a_test_one_does_not(self) -> None:
        self.assertEqual(review_checks.android_manifest_problems('dependencies {\n    testImplementation("junit:junit:4.13.2")\n}'), [])
        self.assertTrue(review_checks.android_manifest_problems('dependencies {\n    implementation("com.squareup.okhttp3:okhttp:4.12.0")\n}'))


class VersionParityTests(unittest.TestCase):
    def test_matching_versions_pass_and_drift_fires(self) -> None:
        swift = 'public static let version = "0.2.0"'
        self.assertEqual(review_checks.version_problems(swift, 'public static final String VERSION = "0.2.0";'), [])
        self.assertIn("0.3.0", review_checks.version_problems(swift, 'public static final String VERSION = "0.3.0";')[0])


class GuardHookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name).resolve()
        (self.root / "Sources" / "ICReadKit").mkdir(parents=True)
        self.file = self.root / "Sources" / "ICReadKit" / "Reader.swift"
        self.file.write_text("let a = 1\n")

    def tearDown(self) -> None:
        self.folder.cleanup()

    def event(self, tool: str, **tool_input) -> dict:
        return {"tool_name": tool, "tool_input": {"file_path": str(self.file), **tool_input}}

    def test_an_edit_adding_logging_is_refused(self) -> None:
        reason = guard.decide(self.event("Edit", old_string="let a = 1", new_string="print(a)"), self.root)
        self.assertIn("ログ", reason)

    def test_a_write_adding_a_url_is_refused(self) -> None:
        reason = guard.decide(self.event("Write", content='let u = "https://x"\n'), self.root)
        self.assertIn("URL", reason)

    def test_ordinary_edits_pass(self) -> None:
        self.assertIsNone(guard.decide(self.event("Edit", old_string="let a = 1", new_string="let a = 2"), self.root))

    def test_an_existing_finding_does_not_block_an_unrelated_edit(self) -> None:
        self.file.write_text("print(a)\nlet a = 1\n")
        self.assertIsNone(guard.decide(self.event("Edit", old_string="let a = 1", new_string="let a = 2"), self.root))

    def test_an_edit_adding_logging_to_the_java_kit_is_refused(self) -> None:
        java = self.root / "android" / "icreadkit" / "src" / "main" / "java" / "Reader.java"
        java.parent.mkdir(parents=True)
        java.write_text("int a = 1;\n")
        event = {"tool_name": "Edit", "tool_input": {"file_path": str(java), "old_string": "int a = 1;", "new_string": "Log.d(TAG, data);"}}
        self.assertIn("ログ", guard.decide(event, self.root))

    def test_files_outside_the_kit_are_left_alone(self) -> None:
        other = self.root / "README.md"
        event = {"tool_name": "Write", "tool_input": {"file_path": str(other), "content": "https://example.com"}}
        self.assertIsNone(guard.decide(event, self.root))


class StopGateTests(unittest.TestCase):
    def test_a_failing_check_blocks_and_a_passing_one_does_not(self) -> None:
        def runner(command, **_):
            failing = command[-1] == "fail"
            return subprocess.CompletedProcess(command, 1 if failing else 0, "", "boom" if failing else "")

        self.assertEqual(stop.failures(Path("."), runner, [["python3", "pass"]]), [])
        found = stop.failures(Path("."), runner, [["python3", "pass"], ["python3", "fail"]])
        self.assertEqual(len(found), 1)
        self.assertIn("boom", found[0])

    def test_the_hook_stays_quiet_on_a_second_stop(self) -> None:
        result = subprocess.run([sys.executable, str(SCRIPTS / "hooks" / "stop_gate.py")],
                                input=json.dumps({"stop_hook_active": True}), capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
