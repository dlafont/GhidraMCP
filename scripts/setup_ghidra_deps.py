#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path


GHIDRA_REPO = "NationalSecurityAgency/ghidra"
DEFAULT_VERSION = "11.3.2"
REQUIRED_ARTIFACTS = (
    "Base",
    "Decompiler",
    "Docking",
    "Generic",
    "Gui",
    "Project",
    "SoftwareModeling",
    "Utility",
)


def github_release_asset_url(version: str) -> str:
    tag = f"Ghidra_{version}_build"
    api_url = f"https://api.github.com/repos/{GHIDRA_REPO}/releases/tags/{tag}"
    with urllib.request.urlopen(api_url) as response:
        release = json.load(response)

    for asset in release.get("assets", []):
        name = asset.get("name", "")
        if name.endswith(".zip") and "PUBLIC" in name:
            return asset["browser_download_url"]

    raise RuntimeError(f"Could not find a public release ZIP for tag {tag}")


def download_file(url: str, destination: Path) -> None:
    print(f"Downloading {url}")
    with urllib.request.urlopen(url) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def resolve_maven_command() -> str:
    explicit = os.environ.get("MAVEN_CMD")
    if explicit:
        explicit_path = Path(explicit)
        if explicit_path.exists():
            return str(explicit_path)

    repo_root = Path(__file__).resolve().parent.parent
    wrapper_name = "mvnw.cmd" if sys.platform.startswith("win") else "mvnw"
    wrapper_path = repo_root / wrapper_name
    if wrapper_path.exists():
        return str(wrapper_path)

    if sys.platform.startswith("win"):
        candidates = ("mvn.cmd", "mvn")
    else:
        candidates = ("mvn",)

    for candidate in candidates:
        resolved = shutil.which(candidate)
        if resolved:
            return resolved

    home = Path.home()
    if sys.platform.startswith("win"):
        glob_pattern = ".maven/maven-*/bin/mvn.cmd"
    else:
        glob_pattern = ".maven/maven-*/bin/mvn"

    installed = sorted(home.glob(glob_pattern), reverse=True)
    for candidate in installed:
        if candidate.exists():
            return str(candidate)

    raise RuntimeError("Could not find Maven on PATH. Install Maven 3.9+ and retry.")


def find_jar(archive: zipfile.ZipFile, artifact_id: str) -> str:
    jar_name = f"{artifact_id}.jar"
    for entry in archive.namelist():
        if entry.endswith(f"/{jar_name}") or entry == jar_name:
            return entry
    raise RuntimeError(f"Could not find {jar_name} in the downloaded Ghidra release")


def install_artifact(maven_cmd: str, jar_path: Path, artifact_id: str, version: str) -> None:
    command = [
        maven_cmd,
        "--batch-mode",
        "install:install-file",
        f"-Dfile={jar_path}",
        "-DgroupId=ghidra",
        f"-DartifactId={artifact_id}",
        f"-Dversion={version}",
        "-Dpackaging=jar",
        "-DgeneratePom=true",
    ]
    subprocess.run(command, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Download Ghidra and install required jars into the local Maven repository.")
    parser.add_argument("--version", default=DEFAULT_VERSION, help="Ghidra version to install (default: 11.3.2)")
    parser.add_argument("--keep-download", action="store_true", help="Keep the downloaded ZIP after installation")
    args = parser.parse_args()

    maven_cmd = resolve_maven_command()

    with tempfile.TemporaryDirectory(prefix="ghidra-mcp-") as temp_dir:
        temp_path = Path(temp_dir)
        archive_path = temp_path / f"ghidra_{args.version}.zip"
        extract_dir = temp_path / "extract"
        extract_dir.mkdir(parents=True, exist_ok=True)

        asset_url = github_release_asset_url(args.version)
        download_file(asset_url, archive_path)

        with zipfile.ZipFile(archive_path) as archive:
            for artifact_id in REQUIRED_ARTIFACTS:
                entry_name = find_jar(archive, artifact_id)
                jar_path = extract_dir / f"{artifact_id}.jar"
                with archive.open(entry_name) as source, jar_path.open("wb") as destination:
                    shutil.copyfileobj(source, destination)
                print(f"Installing ghidra:{artifact_id}:{args.version}")
                install_artifact(maven_cmd, jar_path, artifact_id, args.version)

        if args.keep_download:
            preserved = Path.cwd() / archive_path.name
            shutil.copy2(archive_path, preserved)
            print(f"Preserved download at {preserved}")

    print("Ghidra dependencies installed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())