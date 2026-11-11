#!/usr/bin/env python3
"""ICReadKit doctor: finds the integration mistakes host apps most often ask support about.

  python3 scripts/icreadkit_doctor.py ios path/to/App.app [--entitlements App.entitlements]
  python3 scripts/icreadkit_doctor.py ios path/to/App.ipa
  python3 scripts/icreadkit_doctor.py android path/to/app.apk|kit.aar

Each finding has an ID that matches docs/support/troubleshooting.md, a cause and a fix,
so a support reply can start from the doctor's output instead of from a guess.
It reads only configuration and binary headers, never user data. Standard library only.
"""
import argparse
import plistlib
import re
import struct
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

JPKI_AID = "D392F000260100000001"
KIT_MINIMUM_IOS = (16, 0)
KIT_MINIMUM_SDK = 26
PAGE_16K = 0x4000


@dataclass(frozen=True)
class Finding:
    id: str
    severity: str  # "error" stops a build or a read; "warning" may
    message: str
    fix: str

    def render(self) -> str:
        return f"[{self.severity}] {self.id} {self.message}\n    直し方: {self.fix}\n    詳しく: docs/support/troubleshooting.md#{self.id.lower()}"


def version_tuple(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", text)[:3]) or (0,)


# iOS


def check_ios(info: dict, entitlements: dict | None, embedded_ids: list[str]) -> list[Finding]:
    found = []
    if not str(info.get("NFCReaderUsageDescription", "")).strip():
        found.append(Finding("ICR-IOS-001", "error", "Info.plist に NFCReaderUsageDescription がない。",
                             "利用目的の文言を入れる。ない場合、読み取りシートを開く前に CardReader.availability() が missingUsageDescription を返す。"))
    identifiers = [str(item).upper() for item in info.get("com.apple.developer.nfc.readersession.iso7816.select-identifiers", [])]
    if JPKI_AID not in identifiers:
        found.append(Finding("ICR-IOS-002", "error", f"Info.plist の select-identifiers に {JPKI_AID} がない。",
                             f"com.apple.developer.nfc.readersession.iso7816.select-identifiers に {JPKI_AID} を足す。"))
    minimum = version_tuple(str(info.get("MinimumOSVersion", "0")))
    if minimum < KIT_MINIMUM_IOS:
        found.append(Finding("ICR-IOS-003", "error", f"最低対応 OS が {'.'.join(map(str, minimum))}。ICReadKit は iOS 16 以降が要る。",
                             "アプリの Deployment Target を 16.0 以上にする。"))
    if entitlements is None:
        found.append(Finding("ICR-IOS-010", "warning", "entitlements を確認できなかった。",
                             "--entitlements でファイルを渡すか、署名済みの .app を渡す。"))
    else:
        formats = [str(item) for item in entitlements.get("com.apple.developer.nfc.readersession.formats", [])]
        if "TAG" not in formats:
            found.append(Finding("ICR-IOS-004", "error", "entitlements の NFC の形式に TAG がない。",
                                 "com.apple.developer.nfc.readersession.formats に TAG を入れる。"))
        if "NDEF" in formats and minimum >= (13, 0):
            found.append(Finding("ICR-IOS-005", "error", "最低対応 OS が iOS 13 以降なのに、NFC の形式に NDEF がある。App Store へのアップロードで ITMS-90778 になると報告されている。",
                                 "NDEF を外して TAG だけにする。ICReadKit は NDEF を使わない。"))
    seen: dict[str, int] = {}
    for identifier in embedded_ids:
        seen[identifier] = seen.get(identifier, 0) + 1
    for identifier, count in sorted(seen.items()):
        if count > 1:
            found.append(Finding("ICR-IOS-006", "error", f"埋め込まれた {count} つのバンドルが同じ識別子 {identifier} を持つ。アップロードで ITMS-90685 になる。",
                                 "同じフレームワークを本体と App Clip や拡張の両方に埋め込んでいないか、SDK が抱えた依存を別に入れていないかを見る。"))
    return found


def read_ios_bundle(path: Path, entitlements_path: Path | None) -> tuple[dict, dict | None, list[str]]:
    """Reads the app's Info.plist, entitlements and every embedded bundle identifier."""
    if path.suffix == ".ipa":
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            app_info = next(n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
            info = plistlib.loads(archive.read(app_info))
            nested = [n for n in names if n != app_info and n.endswith("/Info.plist") and re.search(r"\.(framework|appex|app)/Info\.plist$", n)]
            embedded = [plistlib.loads(archive.read(n)).get("CFBundleIdentifier", "") for n in nested]
        return info, plistlib.load(entitlements_path.open("rb")) if entitlements_path else None, [e for e in embedded if e]

    info = plistlib.load((path / "Info.plist").open("rb"))
    embedded = []
    for nested in sorted(path.rglob("Info.plist")):
        if nested.parent == path or not re.search(r"\.(framework|appex|app)$", nested.parent.name):
            continue
        identifier = plistlib.load(nested.open("rb")).get("CFBundleIdentifier")
        if identifier:
            embedded.append(identifier)
    entitlements = None
    if entitlements_path:
        entitlements = plistlib.load(entitlements_path.open("rb"))
    else:
        signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(path)], capture_output=True)
        if signed.returncode == 0 and signed.stdout.strip():
            entitlements = plistlib.loads(signed.stdout)
    return info, entitlements, embedded


# Android


def elf_load_alignments(data: bytes) -> list[int]:
    """The p_align of every PT_LOAD segment in a 64-bit little-endian ELF, or [] if it is not one."""
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return []
    phoff = struct.unpack_from("<Q", data, 0x20)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    alignments = []
    for index in range(phnum):
        offset = phoff + index * phentsize
        if offset + 56 > len(data):
            break
        p_type = struct.unpack_from("<I", data, offset)[0]
        if p_type == 1:  # PT_LOAD
            alignments.append(struct.unpack_from("<Q", data, offset + 48)[0])
    return alignments


def check_android(entries: dict[str, bytes], manifest: str | None, is_library: bool) -> list[Finding]:
    found = []
    for name, data in sorted(entries.items()):
        if not name.endswith(".so") or not re.search(r"(^|/)(lib|jni)/(arm64-v8a|x86_64)/", name):
            continue
        alignments = elf_load_alignments(data)
        if alignments and min(alignments) < PAGE_16K:
            found.append(Finding("ICR-AND-001", "error", f"{name} の LOAD セグメントが {min(alignments)} バイト境界で、16 KB ページに揃っていない。",
                                 "NDK r28 以降でビルドし直す（それ以前はリンカーに -Wl,-z,max-page-size=16384）。外から持ってきた .so は 16 KB 対応版に替える。"))
    if manifest is not None:
        if "android.permission.NFC" not in manifest:
            found.append(Finding("ICR-AND-002", "error", "AndroidManifest に android.permission.NFC がない。",
                                 '<uses-permission android:name="android.permission.NFC" /> を足す（ICReadKit の AAR を使えば自動で入る）。'))
        min_sdk = re.search(r'minSdkVersion="(\d+)"', manifest)
        if min_sdk and int(min_sdk.group(1)) < KIT_MINIMUM_SDK:
            found.append(Finding("ICR-AND-003", "error", f"minSdk が {min_sdk.group(1)}。ICReadKit は API 26 以降が要る。",
                                 "アプリの minSdk を 26 以上にする。"))
        if re.search(r'android\.hardware\.nfc"\s+android:required="true"', manifest):
            found.append(Finding("ICR-AND-004", "warning", "NFC を必須にしているので、NFC のない端末では Play ストアに表示されない。",
                                 'android:required="false" にして、CardReader.availability() で NFC の有無を確かめる。'))
    if is_library and "proguard.txt" not in entries:
        found.append(Finding("ICR-AND-005", "warning", "AAR に consumer 用の keep ルール（proguard.txt）がない。組み込み先の R8 で SDK が壊れることがある。",
                             "consumerProguardFiles で keep ルールを同梱する。"))
    return found


def read_android_archive(path: Path) -> tuple[dict[str, bytes], str | None, bool]:
    with zipfile.ZipFile(path) as archive:
        entries = {n: archive.read(n) for n in archive.namelist() if n.endswith(".so") or n in ("proguard.txt", "AndroidManifest.xml")}
    raw = entries.get("AndroidManifest.xml")
    manifest = None
    if raw is not None:
        # An AAR keeps a text manifest; an APK's is binary XML, which only gives up its strings.
        manifest = raw.decode("utf-8") if raw.lstrip().startswith(b"<") else raw.decode("utf-16-le", errors="ignore")
    return entries, manifest if path.suffix == ".aar" else None, path.suffix == ".aar"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="platform", required=True)
    ios = sub.add_parser("ios")
    ios.add_argument("bundle", type=Path)
    ios.add_argument("--entitlements", type=Path)
    android = sub.add_parser("android")
    android.add_argument("archive", type=Path)
    args = parser.parse_args(argv)

    if args.platform == "ios":
        findings = check_ios(*read_ios_bundle(args.bundle, args.entitlements))
    else:
        findings = check_android(*read_android_archive(args.archive))

    for finding in findings:
        print(finding.render())
    errors = sum(f.severity == "error" for f in findings)
    print(f"ICReadKit doctor: error {errors} 件, warning {len(findings) - errors} 件")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
