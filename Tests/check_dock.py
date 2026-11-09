#!/usr/bin/env python3
"""Exercise Dock settings restoration with fake preferences, not the real Dock."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
build = root / '.build'
build.mkdir(exist_ok=True)
binary = build / 'dock-checks'
subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(build / 'module-cache'),
                str(root / 'Sources/DockSession.swift'), str(root / 'Tests/DockTests.swift'),
                '-o', str(binary)], check=True)
with tempfile.TemporaryDirectory(prefix='pizza-dock-test-') as fixture:
    subprocess.run([str(binary), fixture], check=True)
