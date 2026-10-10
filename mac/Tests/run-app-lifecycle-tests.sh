#!/usr/bin/env bash
set -euo pipefail
if [[ $(uname -s) != Darwin ]]; then
    echo 'Production app lifecycle tests require macOS.'
    exit 77
fi
test_source=${1:?Usage: run-app-lifecycle-tests.sh /path/to/androp.app}
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/androp-lifecycle.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
ditto "$test_source" "$test_dir/androp.app"
mkdir -p "$test_dir/home"
python3 - "$test_dir/androp.app/Contents/Info.plist" <<'PY'
import plistlib, sys, uuid
path = sys.argv[1]
with open(path, 'rb') as stream:
    info = plistlib.load(stream)
info['CFBundleIdentifier'] = 'app.androp.mac.lifecycle-test.' + str(uuid.uuid4())
with open(path, 'wb') as stream:
    plistlib.dump(info, stream)
PY
codesign --force --deep --sign - --timestamp=none "$test_dir/androp.app"
python3 - "$test_dir" <<'PY'
import os, signal, socket, subprocess, sys
root = sys.argv[1]
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = str(probe.getsockname()[1])
env = dict(os.environ, HOME=root + '/home', CFFIXED_USER_HOME=root + '/home',
           ANDROP_LIFECYCLE_SELF_TEST='1')
args = [root + '/androp.app/Contents/MacOS/androp', '--self-test-lifecycle',
        '-isSyncPaused', 'NO', '-appConnectionMode', 'network', '-isBLEEnabled', 'NO',
        '-keepAwakeEnabled', 'NO', '-experimentalClosedLidEnabled', 'NO',
        '-quickShareEnabled', 'NO', '-sendNowPlayingStatus', 'NO',
        '-devicePort', port, '-showInMenubar', 'NO', '-autoStartAtLogin', 'NO']
child = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, start_new_session=True)
try:
    output, _ = child.communicate(timeout=30)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGKILL)
    output, _ = child.communicate()
    print(output, end='')
    raise SystemExit('FAIL: production app lifecycle test exceeded 30 seconds')
print(output, end='')
if child.returncode != 0 or 'LIFECYCLE PASS:' not in output:
    raise SystemExit('FAIL: production app lifecycle test exited ' + str(child.returncode))
PY
