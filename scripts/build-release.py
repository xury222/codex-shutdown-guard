"""Build the standalone Windows ZIP and SHA-256 inventories. Python 3.9+."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
IGNORED_PARTS = {".git", "dist", "__pycache__"}


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
    forbidden = {"config.json", "status.json", "installation.json", ".codex-shutdown-guard-install.json", "ignored-tasks.json", "usage-panel-state.json", "codex-launch-settings.json", "codex-startup-settings.json", "codex-startup-session.json", "codex-startup-stop.json", "auth.json", "credentials.json", "mcp.json", ".mcp.json", "plugin.json", "SKILL.md", "Setup.Plugin.psm1", "package.json", "package-lock.json"}
    for path in files(ROOT):
        rel = path.relative_to(ROOT)
        if path.is_symlink() or path.name in forbidden or set(rel.parts) & {"sessions", "logs", "state", "plugins", ".agents", ".codex-plugin", "server", "node_modules"}:
            raise ValueError(f"Runtime data or link included: {rel}")
        if path.suffix.lower() in {".log", ".pyc", ".lnk", ".zip", ".tmp", ".pem", ".key", ".pfx", ".p12", ".mjs"} or path.name == '.env' or path.name.startswith('.env.'):
            raise ValueError(f"Unexpected artifact: {rel}")
        if path.suffix == ".json":
            json.loads(path.read_text(encoding="utf-8-sig"))
        if path.name == "SKILL.md" and path.read_bytes().startswith(b"\xef\xbb\xbf"):
            raise ValueError("SKILL.md must be UTF-8 without BOM")
    product = json.loads((ROOT / "product.json").read_text(encoding="utf-8"))
    if product["name"] != "codex-shutdown-guard" or product["platform"] != "windows":
        raise ValueError("Unexpected standalone product identity")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", product["version"]):
        raise ValueError("Use a stable semantic version")
    for relative in ("Install.cmd", "Uninstall.cmd", "scripts/Setup.ps1", "scripts/Setup.Core.psm1", "native/Install.ps1", "native/Uninstall.ps1", "native/CodexShutdownGuard.ps1", "native/CodexShutdownGuard.Core.psm1", "native/config.default.json"):
        if not (ROOT / relative).is_file():
            raise ValueError(f"Missing standalone package component: {relative}")
    return product["version"]


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
    source_manifest = {"version": version, "source": "native/", "snapshotDate": "2026-10-27", "notes": "Standalone native monitor and UI source. User configuration, runtime state, sessions, logs and credentials are excluded.", "files": [{"path": p.relative_to(NATIVE).as_posix(), "sha256": digest(p), "bytes": p.stat().st_size} for p in files(NATIVE)]}
    write_json(ROOT / "source-manifest.json", source_manifest)
    inventory(ROOT, "SOURCE_SHA256SUMS.txt")
    check_tree()
    output.mkdir(exist_ok=True, parents=True)
    artifacts = [make_zip(ROOT, output / f"codex-shutdown-guard-windows-{version}.zip", f"codex-shutdown-guard-{version}")]
    (output / "SHA256SUMS.txt").write_text("\n".join(f"{a['sha256']}  {a['file']}" for a in artifacts) + "\n", encoding="utf-8")
    write_json(output / "artifacts.json", artifacts)
    print(json.dumps(artifacts, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
