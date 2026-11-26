#!/usr/bin/env python3
"""Build a clean, Unverum-ready release .zip for Battle Fatigue (Low HP Stance)."""

import os
import zipfile
from pathlib import Path

VERSION = "1.1.0"
ROOT = Path(__file__).resolve().parent.parent
DIST_DIR = ROOT / "dist"
ZIP_PATH = DIST_DIR / f"Battle-Fatigue-Low-HP-Stance-v{VERSION}.zip"

INCLUDE_FILES = [
    "mod.json",
    "README.md",
    "LICENSE",
    "ue4ss/BattleFatigue/enabled.txt",
    "ue4ss/BattleFatigue/Scripts/config.lua",
    "ue4ss/BattleFatigue/Scripts/fatigue_controller.lua",
    "ue4ss/BattleFatigue/Scripts/main.lua",
]


def main() -> None:
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ZIP_PATH, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in INCLUDE_FILES:
            src = ROOT / rel
            if not src.exists():
                raise FileNotFoundError(f"Missing required release file: {src}")
            zf.write(src, arcname=rel)
    print(f"Created: {ZIP_PATH} ({ZIP_PATH.stat().st_size} bytes)")
    with zipfile.ZipFile(ZIP_PATH, "r") as zf:
        for info in zf.infolist():
            print(f"  {info.filename} ({info.file_size} bytes)")


if __name__ == "__main__":
    main()
