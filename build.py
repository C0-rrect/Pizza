#!/usr/bin/env python3
"""Build Pizza Icons from this standalone checkout on Apple Silicon macOS 15+."""
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / '.build'
SOURCE = ROOT / 'Sources'
APP = ROOT / 'dist/Pizza Icons.app'


def run(args):
    subprocess.run(list(map(str, args)), check=True)


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This build targets Apple Silicon macOS 15 or later.')
    BUILD.mkdir(exist_ok=True)
    if APP.exists():
        shutil.rmtree(APP)
    mac = APP / 'Contents/MacOS'
    resources = APP / 'Contents/Resources'
    mac.mkdir(parents=True)
    shutil.copytree(ROOT / 'Assets', resources)
    info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
    (APP / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    swift = ['xcrun', 'swiftc', '-O', '-target', 'arm64-apple-macos15.0',
             '-file-prefix-map', str(ROOT) + '=.', '-debug-prefix-map', str(ROOT) + '=.',
             '-module-cache-path', BUILD / 'module-cache']
    for name in ['CacheBridge', 'Authorization', 'DockSpace']:
        run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=15.0',
             '-ffile-prefix-map=' + str(ROOT) + '=.',
             '-c', SOURCE / (name + '.m'), '-o', BUILD / (name + '.o')])
    run(swift + [SOURCE / 'CacheWriter.swift', '-o', resources / 'CacheWriter'])
    run(swift + ['-parse-as-library', SOURCE / 'DockSession.swift',
                 SOURCE / 'DockGuardian.swift', '-o', resources / 'DockGuardian'])
    main_sources = [
        'Engine', 'CacheEngine', 'CacheStorage', 'DisplaySync', 'DockSession',
        'DockArtwork', 'PixelDock', 'DockResize', 'DockMenu', 'DockLayout',
        'DockWindows', 'DockFolders', 'DockWindowGallery', 'DockPermissionControls',
        'DockAnchors', 'DockDrops', 'DockInteractionTests', 'DockVisibility',
        'DockTransition', 'DockCompositor', 'Model', 'Tests', 'App',
    ]
    run(swift + ['-parse-as-library'] + [SOURCE / (n + '.swift') for n in main_sources]
        + [BUILD / (n + '.o') for n in ['CacheBridge', 'Authorization', 'DockSpace']]
        + ['-framework', 'Security', '-o', mac / 'PizzaIcons'])
    for path in [resources / 'CacheWriter', resources / 'DockGuardian', APP]:
        run(['codesign', '--force', '--sign', '-', path])
    run(['codesign', '--verify', '--deep', '--strict', APP])
    print(APP)


if __name__ == '__main__':
    main()
