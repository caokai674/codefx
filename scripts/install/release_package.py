#!/usr/bin/env python3
"""Deterministic Codefx release preparation and native package smoke checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize():
    root = Path('codex-rs')
    version = tomllib.loads((root / 'Cargo.toml').read_text())['workspace']['package']['version']
    original = (root / 'Cargo.lock').read_text()
    parts = original.split('[[package]]\n')
    for i in range(1, len(parts)):
        pkg = tomllib.loads(parts[i])
        if 'source' not in pkg and pkg['version'] == '0.0.0':
            parts[i] = parts[i].replace('version = "0.0.0"', f'version = "{version}"', 1)
    updated = '[[package]]\n'.join(parts)
    if re.search(r'"[^"\n]+ 0\.0\.0"', updated):
        raise RuntimeError('Version-qualified local lock references require a source repair')
    for old, new in zip(tomllib.loads(original)['package'], tomllib.loads(updated)['package'], strict=True):
        expected = dict(old)
        if 'source' not in old and old['version'] == '0.0.0':
            expected['version'] = version
        if expected != new:
            raise RuntimeError('Dependency resolution changed')
    (root / 'Cargo.lock').write_text(updated, newline='\n')


def verify(archive, target, version):
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp)
        with tarfile.open(archive) as tar:
            for member in tar:
                if not (member.isfile() or member.isdir()):
                    raise RuntimeError(f'Unexpected archive type: {member.name}')
                if member.name.startswith('/') or '..' in Path(member.name).parts or '\\' in member.name:
                    raise RuntimeError(f'Unsafe archive path: {member.name}')
            tar.extractall(dest, filter='data')
        meta = json.loads((dest / 'codex-package.json').read_text())
        for key, value in {'version': version, 'target': target, 'entrypoint': 'bin/codex.exe' if 'windows' in target else 'bin/codex'}.items():
            if meta.get(key) != value:
                raise RuntimeError(f'Package metadata mismatch: {key}')
        suffix = '.exe' if 'windows' in target else ''
        binary = dest / 'bin' / f'codex{suffix}'
        output = subprocess.check_output([str(binary), '--version'], text=True, timeout=60).strip()
        if output != f'codefx {version}':
            raise RuntimeError(f'Unexpected version: {output}')
        required = [f'bin/codex-code-mode-host{suffix}', f'codex-path/rg{suffix}']
        if 'linux' in target:
            required.append('codex-resources/bwrap')
        if 'windows' in target:
            required += ['codex-resources/codex-command-runner.exe', 'codex-resources/codex-windows-sandbox-setup.exe']
        for name in required:
            if not (dest / name).is_file():
                raise RuntimeError(f'Missing package resource: {name}')
        subprocess.run([str(dest / f'codex-path/rg{suffix}'), '--version'], check=True, timeout=30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['normalize', 'verify', 'manifest'])
    parser.add_argument('--target')
    parser.add_argument('--version')
    parser.add_argument('--directory', type=Path, default=Path('dist'))
    args = parser.parse_args()
    if args.action == 'normalize':
        normalize()
    elif args.action == 'verify':
        archive = args.directory / f'codex-package-{args.target}.tar.gz'
        verify(archive, args.target, args.version)
        checksum_path = args.directory / f'{args.target}.sha256'
        expected_checksum = [digest(archive), archive.name]
        if checksum_path.exists():
            if checksum_path.read_text().split() != expected_checksum:
                raise RuntimeError('Published platform checksum does not match the verified archive')
        else:
            checksum_path.write_text(f'{expected_checksum[0]}  {archive.name}\n', newline='\n')
        provenance = {'repository': os.getenv('GITHUB_REPOSITORY'), 'tag': os.getenv('RELEASE_TAG'), 'target': args.target,
                      'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                      'archive_sha256': digest(archive)}
        provenance_path = args.directory / f'codefx-build-{args.target}.json'
        if provenance_path.exists():
            if json.loads(provenance_path.read_text()) != provenance:
                raise RuntimeError('Published package provenance does not match the verified source')
        else:
            provenance_path.write_text(json.dumps(provenance, indent=2) + '\n', newline='\n')
    else:
        archives = sorted(args.directory.glob('codex-package-*.tar.gz'))
        if len(archives) != 6:
            raise RuntimeError(f'Expected six architecture packages, found {len(archives)}')
        (args.directory / 'codex-package_SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in archives), newline='\n')


if __name__ == '__main__':
    main()
