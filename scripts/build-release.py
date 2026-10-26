"""Build local Windows/plugin ZIPs and SHA-256 inventories. Python 3.9+."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugins" / "codex-shutdown-guard"
NATIVE = PLUGIN / "skills" / "codex-shutdown-guard" / "assets" / "native"
IGNORED_PARTS = {".git", "dist", "__pycache__", "node_modules"}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(root: Path):
    return sorted((p for p in root.rglob("*") if p.is_file() and not (set(p.relative_to(ROOT).parts) & IGNORED_PARTS)), key=lambda p: p.relative_to(root).as_posix())


def write_json(path: Path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def inventory(root: Path, filename: str):
    entries = [f"{digest(p)}  {p.relative_to(root).as_posix()}" for p in files(root) if p != root / filename]
    (root / filename).write_text("\n".join(entries) + "\n", encoding="utf-8")


def check_tree():
    forbidden = {"config.json", "status.json", "installation.json", ".codex-shutdown-guard-install.json", "ignored-tasks.json", "usage-panel-state.json", "codex-launch-settings.json", "codex-startup-settings.json", "codex-startup-session.json", "codex-startup-stop.json", "auth.json", "credentials.json"}
    for path in files(ROOT):
        rel = path.relative_to(ROOT)
        if path.is_symlink() or path.name in forbidden or set(rel.parts) & {"sessions", "logs", "state"}:
            raise ValueError(f"Runtime data or link included: {rel}")
        if path.suffix.lower() in {".log", ".pyc", ".lnk", ".zip", ".tmp", ".pem", ".key", ".pfx", ".p12"} or path.name == '.env' or path.name.startswith('.env.'):
            raise ValueError(f"Unexpected artifact: {rel}")
        if path.suffix == ".json":
            json.loads(path.read_text(encoding="utf-8-sig"))
        if path.name == "SKILL.md" and path.read_bytes().startswith(b"\xef\xbb\xbf"):
            raise ValueError("SKILL.md must be UTF-8 without BOM")
    portable = json.loads((PLUGIN / "plugin.json").read_text(encoding="utf-8"))
    legacy = json.loads((PLUGIN / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8"))
    if portable["version"] != legacy["version"] or portable["name"] != legacy["name"]:
        raise ValueError("Plugin identities or versions disagree")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", portable["version"]):
        raise ValueError("Use a stable semantic version such as 1.1.0")
    marketplace = json.loads((ROOT / ".agents" / "plugins" / "marketplace.json").read_text(encoding="utf-8"))
    if not (ROOT / marketplace["plugins"][0]["source"]["path"] / "plugin.json").is_file():
        raise ValueError("Marketplace source does not resolve")
    return portable["version"]


def make_zip(root: Path, destination: Path, prefix: str):
    expected = {}
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files(root):
            name = prefix + "/" + path.relative_to(root).as_posix()
            archive.write(path, name)
            expected[name] = digest(path)
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != set(expected):
            raise ValueError("Archive inventory or CRC failure")
        for name in archive.namelist():
            if name.startswith("/") or ".." in Path(name).parts or hashlib.sha256(archive.read(name)).hexdigest() != expected[name]:
                raise ValueError(f"Archive hash or path failure: {name}")
    return {"file": destination.name, "sha256": digest(destination), "bytes": destination.stat().st_size, "files": len(expected)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist", help="ZIP output directory (default: dist)")
    arguments = parser.parse_args()
    output = arguments.output.resolve()
    if output == ROOT or (ROOT in output.parents and output != ROOT / "dist"):
        raise ValueError("Use dist or a directory outside the repository for build output")
    version = check_tree()
    source_manifest = {"version": version, "source": "native/", "snapshotDate": "2026-10-27", "notes": "Latest native monitor and UI source with portable installation and shared installation discovery. User configuration, runtime state, sessions, logs and credentials are excluded.", "files": [{"path": p.relative_to(NATIVE).as_posix(), "sha256": digest(p), "bytes": p.stat().st_size} for p in files(NATIVE)]}
    write_json(PLUGIN / "skills" / "codex-shutdown-guard" / "assets" / "source-manifest.json", source_manifest)
    inventory(PLUGIN, "FILES.sha256")
    inventory(ROOT, "SOURCE_SHA256SUMS.txt")
    check_tree()
    output.mkdir(exist_ok=True, parents=True)
    artifacts = [make_zip(ROOT, output / f"codex-shutdown-guard-windows-{version}.zip", f"codex-shutdown-guard-{version}"), make_zip(PLUGIN, output / f"codex-shutdown-guard-plugin-{version}.zip", "codex-shutdown-guard")]
    (output / "SHA256SUMS.txt").write_text("\n".join(f"{a['sha256']}  {a['file']}" for a in artifacts) + "\n", encoding="utf-8")
    write_json(output / "artifacts.json", artifacts)
    print(json.dumps(artifacts, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
