"""Offline transaction regressions, executed on native Linux and macOS runners."""
import io
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tarfile
import tempfile
import unittest

from test_install_sh import (
    VERSION, create_package_release, refresh_release_digests, repack_release,
    run_installer_in, write_executable, INSTALL_SCRIPT,
)

MAC = platform.system() == 'Darwin'
TARGET = 'aarch64-apple-darwin' if MAC else 'x86_64-unknown-linux-musl'


class Transactions(unittest.TestCase):
    def package(self, root):
        return create_package_release(root, target=TARGET)

    def run_install(self, root, package, **kwargs):
        archive, checksum, metadata = package
        return run_installer_in(root, VERSION, archive_path=archive, checksum_path=checksum,
                                metadata_json=metadata, force_macos=MAC, **kwargs)[0]

    def old_install(self, root):
        release = root / f'codex-home/packages/standalone/releases/{VERSION}-{TARGET}'
        (release / 'bin').mkdir(parents=True)
        old = release / 'bin/codex'
        write_executable(old, "#!/bin/sh\nprintf 'codex-cli old-preserved\\n'\n")
        current = release.parent.parent / 'current'
        current.symlink_to(release)
        visible = root / 'install-bin/codex'
        visible.parent.mkdir()
        visible.symlink_to(current / 'bin/codex')
        return old, visible, current

    def test_dry_run_has_no_installation_or_profile_side_effects(self):
        with tempfile.TemporaryDirectory(prefix='codefx space ') as tmp:
            root = Path(tmp)
            result = self.run_install(root, self.package(root), arguments=('--dry-run',))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / 'codex-home').exists())
            self.assertFalse((root / 'home/.profile').exists())
            self.assertFalse((root / 'install-bin').exists())

    def test_rejects_traversal_links_and_metadata_mismatch(self):
        for bad in ('traversal', 'symlink', 'hardlink', 'target', 'entrypoint'):
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); package = self.package(root)
                archive, checksum, metadata = package
                old, visible, current = self.old_install(root)
                before = old.read_bytes()
                if bad in ('target', 'entrypoint'):
                    meta = root / 'package/codex-package.json'
                    data = json.loads(meta.read_text()); data[bad] = 'incorrect'
                    meta.write_text(json.dumps(data)); repack_release(root, archive)
                else:
                    # Add a malicious member to an otherwise complete archive.
                    with tarfile.open(archive, 'r:gz') as source:
                        members = [(m, source.extractfile(m).read() if m.isfile() else None) for m in source]
                    with tarfile.open(archive, 'w:gz') as dest:
                        for member, data in members: dest.addfile(member, io.BytesIO(data) if data is not None else None)
                        entry = tarfile.TarInfo('../../escape' if bad == 'traversal' else 'bad-link')
                        if bad != 'traversal':
                            entry.type = tarfile.SYMTYPE if bad == 'symlink' else tarfile.LNKTYPE
                            entry.linkname = '../../escape'
                        dest.addfile(entry)
                metadata = refresh_release_digests(archive, checksum, metadata)
                result = self.run_install(root, (archive, checksum, metadata))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(old.read_bytes(), before)
                self.assertEqual(visible.resolve(), old)
                self.assertFalse((root / 'escape').exists())

    def test_entrypoint_failure_restores_same_version_bytes_and_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); package = self.package(root)
            old, visible, current = self.old_install(root); before = old.read_bytes()
            (root / 'home').mkdir(); profile = root / 'home/.profile'; profile.write_text('# preserve profile\n')
            # A real failed filesystem operation after release validation and commit.
            (root / 'bin').mkdir()
            write_executable(root / 'bin/ln', f'''#!/bin/sh
case "$*" in *install-bin*) if [ ! -f "{root}/failed-once" ]; then touch "{root}/failed-once"; exit 73; fi ;; esac
exec /bin/ln "$@"
''')
            result = self.run_install(root, package)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(old.read_bytes(), before)
            self.assertEqual(profile.read_text(), '# preserve profile\n')
            self.assertEqual(current.resolve(), old.parent.parent)
            self.assertEqual(visible.resolve(), old)
            self.assertFalse((current.parent / '.transaction').exists())

    def test_recovery_of_interrupted_selection_precedes_next_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); package = self.package(root)
            old, visible, current = self.old_install(root)
            tx = current.parent / '.transaction'; tx.mkdir()
            (tx / 'current.path').write_text(str(current) + '\n')
            (tx / 'current.link').write_text(str(old.parent.parent) + '\n')
            current.unlink(); current.symlink_to('/nonexistent/interrupted-release')
            result = self.run_install(root, package)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Recovering an interrupted', result.stderr)
            self.assertEqual(subprocess.check_output([str(visible), '--version'], text=True).strip(), f'codefx {VERSION}')

    def test_process_inspection_failure_is_fail_closed(self):
        # Invoke the real helper with a failing OS process provider.
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        with tempfile.TemporaryDirectory() as tmp:
            code = prefix + f'\ntmp_dir={shlex.quote(tmp)}\nps() {{ return 9; }}\ncf_processes\n'
            result = subprocess.run(['/bin/sh'], input=code, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Cannot inspect', result.stderr)

    def test_native_process_inventory_and_ancestor_guard(self):
        # This checks the actual native ps column format; local restricted hosts skip.
        result = subprocess.run(['ps', '-p', str(os.getpid()), '-o', 'pid=', '-o', 'ppid=', '-o', 'comm='], capture_output=True, text=True)
        if result.returncode: self.skipTest('runtime does not expose native process inspection')
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        with tempfile.TemporaryDirectory() as tmp:
            code = prefix + f'\ntmp_dir={shlex.quote(tmp)}\ncf_processes\n'
            result = subprocess.run(['/bin/sh'], input=code, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_bounded_command_does_not_hang(self):
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        code = prefix + '\nCF_TIMEOUT=1\ncf_run /bin/sh -c "exec sleep 60"\n'
        result = subprocess.run(['/bin/sh'], input=code, text=True, capture_output=True, timeout=8)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__': unittest.main()
