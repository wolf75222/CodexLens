#!/usr/bin/env python3
"""Local development launcher. Never stops an unowned Lens process."""
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent


class LaunchError(Exception):
    pass


def process_path(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return Path(os.fsdecode(buffer.value)).resolve()


def process_start(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='],
                            capture_output=True, text=True,
                            env={**os.environ, 'LC_ALL': 'C'})
    return result.stdout.strip() if result.returncode == 0 else None


def lens_bundle(executable):
    if executable is None or executable.parent.name != 'MacOS':
        return None
    bundle = executable.parent.parent.parent
    info = bundle / 'Contents/Info.plist'
    try:
        metadata = plistlib.loads(info.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None
    if not isinstance(metadata, dict):
        return None
    identifier = metadata.get('CFBundleIdentifier', '')
    if not isinstance(identifier, str):
        return None
    if identifier == 'fr.codexlens.inspector' or identifier.startswith('fr.codexlens.qa.'):
        return bundle.resolve()
    return None


def running_lens():
    result = subprocess.run(['/bin/ps', '-axo', 'pid='], capture_output=True, text=True, check=True)
    instances = []
    for value in result.stdout.split():
        pid = int(value)
        path = process_path(pid)
        if lens_bundle(path) is not None:
            instances.append((pid, path))
    return instances


def same_process(record):
    return (process_path(record['pid']) == Path(record['executable']).resolve()
            and process_start(record['pid']) == record['started'])


def load_record(path):
    if not path.exists():
        return None
    try:
        record = json.loads(path.read_text())
        if (type(record.get('pid')) is not int or record['pid'] <= 0
                or not isinstance(record.get('executable'), str)
                or not isinstance(record.get('started'), str) or not record['started']):
            raise ValueError('invalid process identity')
        return record
    except (OSError, ValueError, TypeError, AttributeError) as error:
        raise LaunchError('Unreadable launch record; refusing to stop a process.') from error


def save_record(path, record):
    temporary = path.with_suffix('.temporary')
    with temporary.open('w') as stream:
        os.chmod(temporary, 0o600)
        json.dump(record, stream)
        stream.write('\n')
    temporary.replace(path)


def request_native_quit(record):
    subprocess.run(['/usr/bin/xcrun', 'swift', str(ROOT / 'scripts/terminate-local.swift'),
                    str(record['pid']), record['executable'], record['started']],
                   check=True, timeout=30)


def stop_owned(record_path, executable, timeout=8):
    record = load_record(record_path)
    if record is None:
        return {'status': 'not-owned', 'stopped': False}
    if Path(record['executable']).resolve() != executable.resolve():
        raise LaunchError('The launch record belongs to a different executable.')
    if not same_process(record):
        record_path.unlink()
        return {'status': 'stale-record', 'stopped': False}
    # PID, exact executable path and start time are rechecked by the native
    # helper. The ordinary termination delegate preserves draft/client cleanup.
    if not same_process(record):
        raise LaunchError('Process identity changed; nothing was stopped.')
    request_native_quit(record)
    deadline = time.monotonic() + timeout
    while same_process(record) and time.monotonic() < deadline:
        time.sleep(0.05)
    if same_process(record):
        raise LaunchError('The owned process did not stop; no new instance was launched.')
    record_path.unlink(missing_ok=True)
    return {'status': 'stopped', 'stopped': True, 'pid': record['pid'], 'method': 'native-quit'}


def choose_instance(instances, executable):
    executable = executable.resolve()
    matching = [pid for pid, path in instances if path.resolve() == executable]
    others = [str(path) for _, path in instances if path.resolve() != executable]
    if others:
        raise LaunchError('Another copy of Lens is running; no new copy was launched: ' + ', '.join(others))
    if len(matching) > 1:
        raise LaunchError('Several matching instances exist; close them before local iteration.')
    return matching[0] if matching else None


def run(args):
    app = args.app.resolve()
    executable = app / 'Contents/MacOS/CodexLens'
    state = args.state_dir.resolve()
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    record_path = state / 'process.json'
    lock_path = state / 'launch.lock'
    with lock_path.open('a') as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == 'stop':
            return stop_owned(record_path, executable)
        existing = choose_instance(running_lens(), executable)
        if existing is not None:
            if not args.restart:
                return {'status': 'already-running', 'pid': existing, 'buildSkipped': True}
            record = load_record(record_path)
            if record is None or record['pid'] != existing or not same_process(record):
                raise LaunchError('This instance was not started by this launcher; refusing to restart it.')
            stop_owned(record_path, executable)
        if not args.no_build:
            build = [str(ROOT / 'scripts/build.sh')]
            if args.debug:
                build.append('--debug')
            subprocess.run(build, cwd=ROOT, env={**os.environ, 'LENS_APP_PATH': str(app)}, check=True)
        if not executable.is_file() or not os.access(executable, os.X_OK) or lens_bundle(executable) != app:
            raise LaunchError('Build did not produce a valid Lens app.')
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        # A copy started outside this launcher during compilation is also a conflict.
        existing = choose_instance(running_lens(), executable)
        if existing is not None:
            return {'status': 'already-running', 'pid': existing}
        command = [str(executable), *args.app_arguments]
        if args.test_network_denied:
            command = ['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)', *command]
        child = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
        try:
            child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        if child.poll() is not None:
            raise LaunchError('Lens exited during startup; no successful launch recorded.')
        started = process_start(child.pid)
        if process_path(child.pid) != executable or not started:
            raise LaunchError('Startup process identity could not be verified.')
        record = {'pid': child.pid, 'executable': str(executable), 'started': started,
                  'app': str(app), 'networkDeniedForTest': args.test_network_denied}
        save_record(record_path, record)
        return {'status': 'started', **record, 'interactionVerified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['run', 'stop'])
    parser.add_argument('--app', type=Path, default=Path(os.environ.get('LENS_APP_PATH', ROOT / 'dist/Codex Lens.app')))
    parser.add_argument('--state-dir', type=Path, default=ROOT / '.lens-run')
    parser.add_argument('--restart', action='store_true', help='Stop only this launcher’s owned instance before rebuilding. Save pending drafts first.')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--debug', action='store_true')
    parser.add_argument('--test-network-denied', action='store_true', help='Anonymous QA only: deny network for the launched process.')
    raw = sys.argv[1:]
    divider = raw.index('--') if '--' in raw else len(raw)
    args = parser.parse_args(raw[:divider])
    args.app_arguments = raw[divider + 1:]
    if sys.platform != 'darwin':
        parser.error('This launch helper requires macOS.')
    if args.test_network_denied and not args.no_build:
        parser.error('Use --no-build with an already prepared anonymous QA app.')
    try:
        print(json.dumps(run(args), indent=2))
    except (LaunchError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
