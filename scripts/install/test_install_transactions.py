"""Offline transaction regressions, executed on native Linux and macOS runners."""
import io
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
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
            root = Path(tmp).resolve()
            result = self.run_install(root, self.package(root), arguments=('--dry-run',))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / 'codex-home').exists())
            self.assertFalse((root / 'home/.profile').exists())
            self.assertFalse((root / 'install-bin').exists())

    def test_rejects_traversal_links_and_metadata_mismatch(self):
        for bad in ('traversal', 'symlink', 'hardlink', 'target', 'entrypoint'):
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve(); package = self.package(root)
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
            root = Path(tmp).resolve(); package = self.package(root)
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
            root = Path(tmp).resolve(); package = self.package(root)
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
            code = prefix + f'\ntmp_dir={shlex.quote(tmp)}\nos=darwin\nps() {{ return 9; }}\ncf_processes\n'
            result = subprocess.run(['/bin/sh'], input=code, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Cannot inspect', result.stderr)

    def test_native_process_inventory_and_ancestor_guard(self):
        # This checks the actual native ps column format; local restricted hosts skip.
        result = subprocess.run(['ps', '-p', str(os.getpid()), '-o', 'pid=', '-o', 'ppid=', '-o', 'comm='], capture_output=True, text=True)
        if result.returncode: self.skipTest('runtime does not expose native process inspection')
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        with tempfile.TemporaryDirectory() as tmp:
            code = prefix + f'\ntmp_dir={shlex.quote(tmp)}\nos={"darwin" if MAC else "linux"}\ncf_processes\n'
            result = subprocess.run(['/bin/sh'], input=code, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_daemon_migration_preserves_running_state_and_rolls_back_failure(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve(); archive, sums, meta = self.package(root)
                old, visible, current = self.old_install(root); before = old.read_bytes()
                settings = root / 'codex-home/app-server-daemon/settings.json'
                settings.parent.mkdir(); settings.write_text('{"original":true}')
                state = root / 'daemon-running'; state.touch()
                (root / 'bin').mkdir()
                old_cli = root / 'bin/codex'
                write_executable(old_cli, f"""#!/bin/sh
case "$*" in
  --version) echo 'codex-cli 0.163.0' ;;
  *'daemon version') echo '{{"status":"running","appServerVersion":"0.163.0"}}' ;;
  *'daemon stop') rm -f {shlex.quote(str(state))} ;;
  *'daemon start') touch {shlex.quote(str(state))} ;;
  *) exit 1 ;;
esac
""")
                new_cli = root / 'package/bin/codex'
                write_executable(new_cli, f"""#!/bin/sh
case "$*" in
  --version) echo 'codefx {VERSION}' ;;
  *'daemon update --from-cli --yes') {'exit 71' if fail else ':'} ;;
  *'daemon version') echo '{{"status":"running","appServerVersion":"{VERSION}"}}' ;;
  *'daemon stop') rm -f {shlex.quote(str(state))} ;;
  *'daemon start') touch {shlex.quote(str(state))} ;;
  *) exit 1 ;;
esac
""")
                repack_release(root, archive); meta = refresh_release_digests(archive, sums, meta)
                result = self.run_install(root, (archive, sums, meta), arguments=('--stop-running',))
                self.assertEqual(result.returncode == 0, not fail, result.stderr)
                self.assertTrue(state.exists(), 'Originally running daemon was not restored')
                self.assertEqual(settings.read_text(), '{"original":true}')
                if fail:
                    self.assertEqual(old.read_bytes(), before)
                    self.assertEqual(visible.resolve(), old.resolve())
                else:
                    self.assertEqual(subprocess.check_output([str(visible), '--version'], text=True).strip(), f'codefx {VERSION}')

    def test_active_session_and_ancestor_are_rejected_before_mutation(self):
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        for stop in (0, 1):
            with self.subTest(stop=stop), tempfile.TemporaryDirectory() as tmp:
                code = prefix + f"""
tmp_dir={shlex.quote(tmp)}
STANDALONE_ROOT="$tmp_dir/install"
CF_STOP_RUNNING={stop}
ps() {{ printf '%s %s S codex\\n' "$$" "$PPID"; }}
cf_prepare
"""
                result = subprocess.run(['/bin/sh'], input=code, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((Path(tmp) / 'install').exists())
                self.assertIn('ancestor' if stop else 'Codex is running', result.stderr)

    def test_install_lock_has_a_bounded_wait(self):
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            code = prefix + f"""
STANDALONE_ROOT={shlex.quote(tmp)}
LOCK_DIR="$STANDALONE_ROOT/install.lock.d"
LOCK_FILE="$STANDALONE_ROOT/install.lock"
os=darwin
CF_LOCK_TIMEOUT=1
# Force the portable mkdir-lock branch, including on Linux.
command() {{ if [ "${{2:-}}" = flock ]; then return 1; fi; command "$@"; }}
mkdir "$LOCK_DIR"
printf '%s\\n' "$$" > "$LOCK_DIR/pid"
date +%s > "$LOCK_DIR/started_at"
acquire_install_lock
"""
            result = subprocess.run(['/bin/sh'], input=code, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('lock timed out', result.stderr)

    def test_symlinked_shell_profile_is_updated_and_failure_restores_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); package = self.package(root)
            self.old_install(root)
            home = root / 'home'; home.mkdir()
            target = home / 'dotfiles.profile'; target.write_text('# my dotfiles\n')
            profile = home / '.profile'; profile.symlink_to(target.name)
            result = self.run_install(root, package)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(profile.is_symlink())
            self.assertIn('# my dotfiles', target.read_text())
            self.assertIn('Codex installer', target.read_text())

    def test_linux_proc_fallback_recognizes_native_package_names(self):
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        with tempfile.TemporaryDirectory() as tmp:
            code = prefix + f"""
tmp_dir={shlex.quote(tmp)}
mkdir -p "$tmp_dir/proc/$$"
printf '%s (codex-x86_64-native) S 1 0 0 0 0 0\\n' "$$" > "$tmp_dir/proc/$$/stat"
printf 'Uid:\\t%s\\t%s\\n' "$(id -u)" "$(id -u)" > "$tmp_dir/proc/$$/status"
cf_proc_inventory "$tmp_dir/proc"
grep codex-x86_64-native "$tmp_dir/processes"
"""
            result = subprocess.run(['/bin/sh'], input=code, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_stop_running_requests_normal_exit_of_native_fixture(self):
        compiler = shutil.which('cc')
        if not compiler: self.skipTest('native C compiler unavailable')
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        with tempfile.TemporaryDirectory(prefix='codefx native process ') as tmp:
            root = Path(tmp).resolve()
            source = root / 'fixture.c'; binary = root / 'codex-fixture'; marker = root / 'closed'
            source.write_text(r"""
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
static int output;
static void done(int sig) { (void)sig; write(output, "closed", 6); _exit(0); }
int main(int argc, char **argv) {
  output = open(argv[1], O_WRONLY | O_CREAT, 0600);
  signal(SIGTERM, done); puts("ready"); fflush(stdout);
  for (;;) pause();
}
""")
            subprocess.run([compiler, str(source), '-o', str(binary)], check=True, capture_output=True)
            proc = subprocess.Popen([str(binary), str(marker)], stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(proc.stdout.readline().strip(), 'ready')
                check = subprocess.run(['ps', '-p', str(proc.pid), '-o', 'pid='], capture_output=True)
                if check.returncode: self.skipTest('runtime process namespace is not inspectable')
                code = prefix + f"""
tmp_dir={shlex.quote(str(root))}
HOME="$tmp_dir/home"; mkdir "$HOME"
os={'darwin' if MAC else 'linux'}
CODEX_HOME_DIR="$HOME/.codex"; STANDALONE_ROOT="$CODEX_HOME_DIR/packages/standalone"
mkdir -p "$STANDALONE_ROOT"
CURRENT_LINK="$STANDALONE_ROOT/current"; AUTO_UPDATE_VERSION="$STANDALONE_ROOT/auto-update-version"
BIN_PATH="$HOME/bin/codex"; CODE_MODE_HOST_BIN_PATH="$HOME/bin/codex-code-mode-host"
CF_STOP_RUNNING=1; CF_TIMEOUT=3
# Restrict the test to its own child; no other account processes can be stopped.
cf_processes() {{
  ps -p {proc.pid} -o pid= -o ppid= -o stat= -o comm= > "$tmp_dir/processes" 2>/dev/null || :
  awk '$3 !~ /^Z/ {{ print $1, $2, $4 }}' "$tmp_dir/processes"
}}
cf_prepare
"""
                result = subprocess.run(['/bin/sh'], input=code, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(proc.wait(timeout=3), 0)
                self.assertEqual(marker.read_text(), 'closed')
            finally:
                if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)
                proc.stdout.close()

    def test_bounded_command_does_not_hang(self):
        prefix = INSTALL_SCRIPT.read_text().split('parse_args "$@"')[0]
        code = prefix + '\nCF_TIMEOUT=1\ncf_run /bin/sh -c "exec sleep 60"\n'
        result = subprocess.run(['/bin/sh'], input=code, text=True, capture_output=True, timeout=8)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__': unittest.main()
