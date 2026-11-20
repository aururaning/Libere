#!/usr/bin/env python3
"""Package a locally built Libere.app and verify the extracted payload.

Run build-mac-package.sh to build first. This command never builds or installs an
app, and never uses a previously promoted MacBuild copy or release manifest.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} exited with {result.returncode}:\n{result.stdout}{result.stderr}')
    return result.stdout


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
    return hasher.hexdigest()


def files(app):
    result = {}
    for path in sorted(app.rglob('*')):
        relative = str(path.relative_to(app))
        if path.is_symlink():
            result[relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            result[relative] = {'sha256': digest(path)}
        elif not path.is_dir():
            raise RuntimeError(f'Unexpected special file in application: {relative}')
    return result


def verify_app(app, expected):
    if files(app) != expected:
        raise RuntimeError(f'Application files changed during packaging: {app}')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))


def validate_build(root, source):
    if not (source / 'Contents/Info.plist').is_file():
        raise RuntimeError('Build Libere first with: bash Scripts/build-mac-local.sh')
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    settings = (root / 'Config/Base.xcconfig').read_text()
    for field, key in [('CFBundleShortVersionString', 'MARKETING_VERSION'),
                       ('CFBundleVersion', 'CURRENT_PROJECT_VERSION'),
                       ('CFBundleIdentifier', 'PRODUCT_BUNDLE_IDENTIFIER')]:
        match = re.search(r'^' + key + r'\s*=\s*(.+)$', settings, re.M)
        if not match or info.get(field) != match.group(1).strip():
            raise RuntimeError(f'Build configuration mismatch: {field}; rebuild Libere first')
    if any(info.get(key) != 'Libere' for key in ('CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable')):
        raise RuntimeError('Expected a Libere application')
    # Resources are copied by the build, so compare them with this source tree.
    resources = source / 'Contents/Resources'
    for name in ('BrandLogo.png', 'notebook_kernel.py', 'libere_agent.py', 'agent_rules.md',
                 'agent_tools.json', 'agent_openapi.json', 'Showcase.json'):
        if digest(resources / name) != digest(root / 'Sources/MarginNotes/Resources' / name):
            raise RuntimeError(f'Stale resource: {name}; rebuild Libere first')
    for name in ('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md'):
        if digest(resources / name) != digest(root / name):
            raise RuntimeError(f'Missing or stale license notice: {name}; rebuild Libere first')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(source))
    return info


def verify_pkg_metadata(expanded):
    info = ET.parse(expanded / 'PackageInfo').getroot()
    if info.get('install-location') != '/Applications' or info.get('relocatable') != 'false':
        raise RuntimeError('Installer must use a fixed /Applications destination')
    bundles = info.findall('bundle')
    if len(bundles) != 1 or bundles[0].get('path') not in ('Libere.app', './Libere.app'):
        raise RuntimeError('Installer contains an unexpected application bundle')
    if info.find('scripts') is not None or (expanded / 'Scripts').exists():
        raise RuntimeError('Installation scripts are not permitted in this package')
    if list((expanded / 'Payload').iterdir()) != [expanded / 'Payload/Libere.app']:
        raise RuntimeError('Installer contains an unexpected payload')


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--format', choices=('dmg', 'pkg'), default='pkg')
    parser.add_argument('--app', type=Path, default=root / '.build/XcodeProducts/Debug/Libere.app',
                        help='Built Libere.app (default: .build/XcodeProducts/Debug/Libere.app)')
    parser.add_argument('--output-dir', type=Path, default=root / 'dist',
                        help='Installer output directory (default: dist)')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        raise RuntimeError('Mac installers must be packaged on macOS')
    source = args.app.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    if output_dir == source or source in output_dir.parents:
        raise RuntimeError('The output directory cannot be inside the source application')
    info = validate_build(root, source)
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version):
        raise RuntimeError('Expected a numeric application version')
    expected_files = files(source)
    arches = run('/usr/bin/lipo', '-archs', str(source / 'Contents/MacOS/Libere')).strip().split()
    if not arches or not set(arches).issubset({'arm64', 'x86_64'}):
        raise RuntimeError('Unexpected Mac application architecture')
    architecture = 'universal' if set(arches) == {'arm64', 'x86_64'} else arches[0]
    name = f'Libere-{version}-{architecture}.{args.format}'
    output = output_dir / name
    checksum = output.with_suffix(output.suffix + '.sha256')
    manifest = output.with_suffix(output.suffix + '.manifest.json')
    for path in (output, checksum, manifest):
        if path.exists() or path.is_symlink():
            raise RuntimeError(f'Refusing to overwrite existing output: {path}')
    with tempfile.TemporaryDirectory(prefix='libere-installer-') as temporary:
        work = Path(temporary)
        stage = work / 'payload'
        stage.mkdir()
        app = stage / 'Libere.app'
        run('/usr/bin/ditto', '--norsrc', '--noextattr', '--noqtn', str(source), str(app))
        # Normalize permissions even when the build lives on an exFAT volume.
        for path in [app, *app.rglob('*')]:
            if not path.is_symlink():
                executable = path == app / 'Contents/MacOS/Libere'
                path.chmod(0o755 if path.is_dir() or executable else 0o644)
        verify_app(app, expected_files)
        installer = work / name
        if args.format == 'dmg':
            (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
            (stage / '安装说明.txt').write_text(
                f'Libere {version}（{build}）\n\n'
                '1. 将 Libere.app 拖入 Applications（应用程序）文件夹。\n'
                '2. 从应用程序文件夹启动 Libere，选择资料库目录。\n'
                '3. 安装完成后推出 Libere 磁盘映像。\n\n'
                f'系统要求：macOS {info["LSMinimumSystemVersion"]} 或更新版本，{architecture}。\n'
                '本脚本不执行发行签名或 Apple 公证。\n'
                'Notebook 执行需要单独配置 Python、jupyter_client 和 ipykernel。\n', encoding='utf-8')
            run('/usr/bin/hdiutil', 'create', '-srcfolder', str(stage), '-volname', 'Libere',
                '-format', 'UDZO', '-fs', 'HFS+', str(installer))
            run('/usr/bin/hdiutil', 'verify', str(installer))
            mount = work / 'mounted'
            mount.mkdir()
            run('/usr/bin/hdiutil', 'attach', str(installer), '-readonly', '-nobrowse', '-mountpoint', str(mount))
            try:
                verify_app(mount / 'Libere.app', expected_files)
                if os.readlink(mount / 'Applications') != '/Applications':
                    raise RuntimeError('Invalid Applications shortcut')
            finally:
                run('/usr/bin/hdiutil', 'detach', str(mount))
        else:
            components = work / 'components.plist'
            run('/usr/bin/pkgbuild', '--analyze', '--root', str(stage), str(components))
            config = plistlib.loads(components.read_bytes())
            if len(config) != 1 or config[0].get('RootRelativeBundlePath') != 'Libere.app':
                raise RuntimeError('Expected one Libere.app package component')
            config[0].update(BundleIsRelocatable=False, BundleIsVersionChecked=True,
                             BundleHasStrictIdentifier=True, BundleOverwriteAction='upgrade')
            components.write_bytes(plistlib.dumps(config))
            run('/usr/bin/pkgbuild', '--root', str(stage), '--component-plist', str(components),
                '--identifier', 'app.libere.mac.installer', '--version', version,
                '--install-location', '/Applications', '--ownership', 'recommended', str(installer))
            expanded = work / 'expanded'
            run('/usr/sbin/pkgutil', '--expand-full', str(installer), str(expanded))
            verify_app(expanded / 'Payload/Libere.app', expected_files)
            verify_pkg_metadata(expanded)
        verify_app(source, expected_files)
        expected_hash = digest(installer)
        output_dir.mkdir(parents=True, exist_ok=True)
        # Exclusive creation also refuses an output created after the preflight.
        with output.open('xb') as target, installer.open('rb') as original:
            shutil.copyfileobj(original, target)
        if digest(output) != expected_hash:
            raise RuntimeError('Installer copy failed verification')
    with checksum.open('x') as stream:
        stream.write(f'{expected_hash}  {name}\n')
    report = {'version': version, 'build': build, 'format': args.format,
              'bundleID': info['CFBundleIdentifier'], 'architecture': arches,
              'minimumMacOS': info['LSMinimumSystemVersion'], 'installer': name,
              'sha256': expected_hash, 'bytes': output.stat().st_size,
              'sourceAppVerified': True, 'packagedAppVerified': True,
              'installerSigned': False, 'notarizationPerformed': False,
              'fileCount': len(expected_files), 'files': expected_files}
    with manifest.open('x') as stream:
        stream.write(json.dumps(report, indent=2) + '\n')
    print(f'Installer: {output}\nSHA256: {expected_hash}\nManifest: {manifest}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(str(error)) from error
