#!/bin/zsh
set -euo pipefail

# Source-matched native component/model qualification, separate from the true
# production-binary QA launcher. Run only after the parent integration freeze.
project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source_root="$project_root"
output=""
corpus=""
entrypoint="DesignPrinciplesMain.swift"
run=0
linger=0
after_freeze=0
baseline_v06=0
while (( $# )); do
  case "$1" in
    --source-root) source_root="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --corpus) corpus="$2"; shift 2 ;;
    --entrypoint) entrypoint="$2"; shift 2 ;;
    --after-source-freeze) after_freeze=1; shift ;;
    --baseline-v06) baseline_v06=1; shift ;;
    --run) run=1; shift ;;
    --linger) linger=1; shift ;;
    *) print -u2 "Unknown argument: $1"; exit 2 ;;
  esac
done
(( after_freeze )) || { print -u2 'Wait for the source freeze; acknowledge it with --after-source-freeze.'; exit 2; }
[[ "$source_root" == /* && "$output" == /* && "$corpus" == /* ]] || { print -u2 'Use absolute source-root/output/corpus paths.'; exit 2; }
[[ "$output" == /private/tmp/* || "$output" == /tmp/* ]] || { print -u2 'Use a new private temporary output directory.'; exit 2; }
[[ ! -e "$output" && "$entrypoint" == *.swift && "$entrypoint" != */* ]] || { print -u2 'Use a new output and a simple Swift entrypoint filename.'; exit 2; }
mkdir -p "$output"
private_scratch="$(mktemp -d /private/tmp/codex-lens-native-design-v07.XXXXXX)"
trap 'rm -rf "$private_scratch"' EXIT
python3 - "$project_root" "$source_root" "$private_scratch" "$output" "$entrypoint" "$baseline_v06" <<'PYCODE'
from pathlib import Path
import hashlib,json,sys
project,source,scratch,out=map(Path,sys.argv[1:5]);entry=sys.argv[5];baseline=bool(int(sys.argv[6]))
files={};originals={}
def resident(path):
    if getattr(path.stat(),'st_flags',0)&0x40000000:raise SystemExit('Refusing SF_DATALESS source: '+str(path))
    return path.read_bytes()
def copy(path,target):
    data=resident(path);target.write_bytes(data)
    key=str(path.relative_to(source)) if path.is_relative_to(source) else str(path.relative_to(project));sha=hashlib.sha256(data).hexdigest()
    files[key]={'bytes':len(data),'sha256':sha,'origin':str(path)};originals[path]=sha
for module in ['LensCore','CSQLite','CodexLens']:
    target=scratch/'Sources'/('NativeDesignV07Probe' if module=='CodexLens' else module);target.mkdir(parents=True)
    for path in sorted((source/'Sources'/module).iterdir()):
        if not path.is_file() or path.name=='CodexLensApp.swift' or path.suffix not in ['.swift','.h','.modulemap']:continue
        copy(path,target/path.name)
target=scratch/'Sources/NativeDesignV07Probe'
copy(project/'Tests/NativeUI'/entry,target/entry)
for path,sha in originals.items():
    if hashlib.sha256(resident(path)).hexdigest()!=sha:raise SystemExit('Source changed while copying; wait for a coherent freeze.')
(out/'native-design-v07-source-manifest.json').write_text(json.dumps({'sourceRoot':str(source),'files':files,'productionEntryPointReplaced':True,'copiedAppSourcesModified':False,'entrypoint':entry,'baselineV06':baseline},indent=2)+'\n')
(scratch/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CodexLensDesignV07Verification", platforms: [.macOS(.v14)], products: [.executable(name: "NativeDesignV07Probe", targets: ["NativeDesignV07Probe"])], targets: [.systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"), .target(name: "LensCore", dependencies: ["CSQLite"]), .executableTarget(name: "NativeDesignV07Probe", dependencies: ["LensCore"])], swiftLanguageModes: [.v5])
''')
PYCODE
/usr/bin/xcrun swift --version > "$output/toolchain.log" 2>&1
/usr/bin/xcrun --sdk macosx --show-sdk-version >> "$output/toolchain.log"
/usr/bin/sw_vers >> "$output/toolchain.log"
/usr/bin/uname -m >> "$output/toolchain.log"
swift_flags=(-Xswiftc -g)
if (( ! baseline_v06 )); then swift_flags+=(-Xswiftc -DV07); fi
if ! swift build -c release "${swift_flags[@]}" --package-path "$private_scratch" --scratch-path "$private_scratch/build" --product NativeDesignV07Probe > "$output/build.log" 2>&1; then
  tail -60 "$output/build.log"; exit 1
fi
probe_bundle="$output/NativeDesignV07Probe.app"
mkdir -p "$probe_bundle/Contents/MacOS"
if [[ -f "$source_root/Assets/Localizations/en.json" ]]; then
    mkdir -p "$probe_bundle/Contents/Resources/Localizations"
    cp "$source_root/Assets/Localizations/en.json" "$probe_bundle/Contents/Resources/Localizations/en.json"
fi
cp "$private_scratch/build/release/NativeDesignV07Probe" "$probe_bundle/Contents/MacOS/NativeDesignV07Probe"
/usr/bin/xcrun dsymutil "$probe_bundle/Contents/MacOS/NativeDesignV07Probe" --out "$output/NativeDesignV07Probe.app.dSYM" > "$output/symbols.log" 2>&1
/usr/bin/xcrun dwarfdump --uuid "$probe_bundle/Contents/MacOS/NativeDesignV07Probe" "$output/NativeDesignV07Probe.app.dSYM" >> "$output/symbols.log"
python3 - "$probe_bundle/Contents/Info.plist" "$output" <<'PYCODE'
import hashlib,plistlib,sys
from pathlib import Path
identifier='fr.codexlens.designprobe.v07.'+hashlib.sha256(sys.argv[2].encode()).hexdigest()[:12]
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier,'CFBundleName':'Codex Lens Design v07 Probe','CFBundleExecutable':'NativeDesignV07Probe','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True}))
PYCODE
/usr/bin/codesign --force --sign - "$probe_bundle" > "$output/sign.log" 2>&1
print "Native source-matched bundle: $probe_bundle"
if (( ! run )); then exit 0; fi
probe_arguments=(--corpus "$corpus" --output "$output")
if (( linger )); then probe_arguments+=(--linger); fi
python3 - "$output" "$probe_bundle/Contents/MacOS/NativeDesignV07Probe" "${probe_arguments[@]}" <<'PYCODE'
from pathlib import Path
import json,subprocess,sys,time
out=Path(sys.argv[1]);args=sys.argv[2:]
command=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)']+args
(out/'command.json').write_text(json.dumps({'command':command,'ownApplicationOnly':True,'networkDeniedByOS':True,'trueProductionEntryPoint':False},indent=2)+'\n')
receipt=out/'native-design-v07-receipt.json';linger='--linger' in args
with (out/'runtime.log').open('wb') as log:
    child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
    deadline=time.monotonic()+120
    while child.poll() is None and not receipt.exists() and time.monotonic()<deadline:time.sleep(.1)
    method='native-exit'
    if receipt.exists() and linger:
        print('Design v07 receipt available; own probe PID',child.pid,flush=True);child.wait()
    elif child.poll() is None:
        try:child.wait(timeout=3 if receipt.exists() else .1)
        except subprocess.TimeoutExpired:
            method='own-probe-SIGTERM-after-receipt' if receipt.exists() else 'own-probe-timeout-SIGTERM'
            child.terminate()
            try:child.wait(timeout=5)
            except subprocess.TimeoutExpired:method='own-probe-SIGKILL';child.kill();child.wait()
    (out/'process-receipt.json').write_text(json.dumps({'pid':child.pid,'exitStatus':child.poll(),'receiptWritten':receipt.exists(),'shutdownMethod':method,'nativeQuitQualified':method=='native-exit' and child.poll()==0,'timeoutSeconds':120},indent=2)+'\n')
if not receipt.exists():raise SystemExit('No receipt; inspect runtime.log')
j=json.loads(receipt.read_text())
if not j.get('allExecutedChecksPassed'):raise SystemExit('Design v07 qualification failed; retain receipt/logs.')
print('DESIGN_V07_'+('PARTIAL' if j.get('unqualified') else 'PASS'),len(j['checks']),'checks')
PYCODE
