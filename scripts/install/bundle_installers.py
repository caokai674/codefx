#!/usr/bin/env python3
"""Package the independently maintained installers after native release checks."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import zipfile


def bundle(source: str, tag: str, output: Path) -> Path:
    if not re.fullmatch(r'[0-9a-f]{40}', source):
        raise ValueError('Installer source must be a full commit SHA')
    if not re.fullmatch(r'rust-v[0-9]+\.[0-9]+\.[0-9]+', tag):
        raise ValueError('Expected a stable Rust release tag')
    root = Path(__file__).resolve().parents[2]
    paths = [f'scripts/install/{name}' for name in
             ('install-codefx.sh', 'install-codefx.ps1', 'install.sh', 'install.ps1')]
    paths.append('docs/codefx-installer.md')
    files = {name: (root / name).read_bytes() for name in paths}
    shell = files[paths[0]].decode()
    old = 'CODEFX_INSTALL_REF="${CODEFX_INSTALL_REF:-main}"'
    assert shell.count(old) == 1, 'Shell bootstrap default changed; review the pin'
    files[paths[0]] = shell.replace(old, f'CODEFX_INSTALL_REF="${{CODEFX_INSTALL_REF:-{source}}}"').encode()
    ps = files[paths[1]].decode()
    old = "$ref = if ($env:CODEFX_INSTALL_REF) { $env:CODEFX_INSTALL_REF } else { 'main' }"
    assert ps.count(old) == 1, 'PowerShell bootstrap default changed; review the pin'
    files[paths[1]] = ps.replace(old, old.replace("'main'", f"'{source}'")).encode()
    files['README.md'] = f'''# Codefx verified installers

Installer source: https://github.com/hitmux/codefx/tree/{source}/scripts/install
Binary release: https://github.com/hitmux/codefx/releases/tag/{tag}

These fixed bootstraps default to installer commit `{source}`. The base installers
are included for review. The bootstraps download that exact base revision over
HTTPS; package downloads and GitHub release metadata require network access.

Linux/macOS: `sh scripts/install/install-codefx.sh`
Windows, ordinary PowerShell: `& ./scripts/install/install-codefx.ps1`

Save work and close active Codex sessions before installation. Options and
recovery details: [installation guide](docs/codefx-installer.md).

The original `{tag}` source archive preserves the binary build revision and
contains historical, unsafe replacement wrappers. Use this installer bundle or
the reviewed installer source linked above when installing.
'''.encode()
    sha256 = lambda data: hashlib.sha256(data).hexdigest()
    provenance = {
        'repository': 'hitmux/codefx', 'installer_source_commit': source,
        'binary_release_tag': tag, 'bootstrap_default_ref': source,
        'changes_from_source': 'Bootstrap defaults pinned to installer_source_commit',
        'files': {name: sha256(data) for name, data in sorted(files.items())},
    }
    files['installer-source.json'] = (json.dumps(provenance, indent=2, sort_keys=True) + '\n').encode()
    files['SHA256SUMS'] = ''.join(f'{sha256(data)}  {name}\n' for name, data in sorted(files.items())).encode()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'codefx-installers-{source[:12]}.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as package:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | (0o755 if name.endswith('.sh') else 0o644)) << 16
            info.compress_type = zipfile.ZIP_STORED
            package.writestr(info, data)
    digest = sha256(archive.read_bytes())
    Path(str(archive) + '.sha256').write_bytes(f'{digest}  {archive.name}\n'.encode())
    print(json.dumps({'archive': str(archive), 'sha256': digest, 'source': source}))
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    bundle(args.source, args.tag, args.output)
