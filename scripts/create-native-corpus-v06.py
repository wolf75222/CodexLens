#!/usr/bin/env python3
"""Create an anonymous, real-on-disk Codex Lens QA corpus. Never reads Codex data."""
import argparse, base64, datetime as dt, hashlib, json, os, struct, subprocess, zlib
from pathlib import Path

ROOT = "11111111-1111-4111-8111-111111111111"
CHILD = "33333333-3333-4333-8333-333333333333"
OTHER = "22222222-2222-4222-8222-222222222222"
EPOCH = dt.datetime(2026, 10, 1, 12, 0, 0, tzinfo=dt.timezone.utc)

def digest(data): return hashlib.sha256(data).hexdigest()
def stamp(ms): return (EPOCH + dt.timedelta(milliseconds=ms)).isoformat(timespec="milliseconds").replace("+00:00", "Z")
def encoded(value): return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
def git(directory, *args):
    env = os.environ.copy()
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0", GIT_AUTHOR_DATE="2026-10-01T12:00:00Z", GIT_COMMITTER_DATE="2026-10-01T12:00:00Z")
    command = ["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Lens QA", "-c", "user.email=qa@example.invalid", *args]
    result = subprocess.run(command, cwd=directory, env=env, capture_output=True, text=True, check=True)
    return result.stdout.strip()

def png():
    def chunk(tag, payload): return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag+payload)&0xffffffff)
    width, height = 96, 64
    raw=b"".join(b"\0"+b"".join(bytes((40 if (x//8+y//8)%2 else 210, 115, 180, 255)) for x in range(width)) for y in range(height))
    return b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",width,height,8,6,0,0,0))+chunk(b"IDAT",zlib.compress(raw))+chunk(b"IEND",b"")

class Stream:
    def __init__(self, start=0): self.records=[]; self.milliseconds=start
    def event(self, kind, payload, advance=100):
        record={"timestamp":stamp(self.milliseconds),"type":kind,"payload":payload}
        self.milliseconds+=advance;self.records.append(record);return record
    def message(self, role, text, extras=None, ident=None):
        payload={"type":"message","role":role,"content":[{"type":"input_text" if role in ("user","developer") else "output_text","text":text}]+(extras or [])}
        if ident:payload["id"]=ident
        return self.event("response_item",payload)
    def call(self, ident, name, args, namespace="functions"):
        return self.event("response_item",{"type":"function_call","call_id":ident,"name":name,"namespace":namespace,"arguments":encoded(args).decode()})
    def result(self, ident, output):return self.event("response_item",{"type":"function_call_output","call_id":ident,"output":output})
    def patch(self, ident, patch):return self.event("response_item",{"type":"custom_tool_call","call_id":ident,"name":"apply_patch","input":patch})
    def patch_result(self, ident, output):return self.event("response_item",{"type":"custom_tool_call_output","call_id":ident,"output":output})

def create(out, target):
    out=out.absolute()
    if out.exists():raise SystemExit("Refusing existing output: "+str(out))
    if not str(out).startswith(("/private/tmp/","/tmp/")):raise SystemExit("Fixture output must be a new private temporary directory")
    out.mkdir(parents=True)
    (out/"ANONYMOUS_FIXTURE").write_text("Generated QA data. No real Codex conversation, authentication, network, or hooks.\n")
    repo=out/"repository";repo.mkdir()
    (repo/"src").mkdir();(repo/"docs").mkdir()
    baseline='import Foundation\n\nstruct Same {\n    static let label = "baseline"\n    static let unicode = "café 東京 — sélection"\n}\n'
    (repo/"src/Same.swift").write_text(baseline)
    (repo/"src/ManualOnly.swift").write_text('let manual = "baseline"\n')
    large_before="".join(f'let line{i:04d} = "before {i}"\n' for i in range(3000))
    large_after="".join(f'let line{i:04d} = "after {i}"\n' for i in range(3000))
    (repo/"src/Large.swift").write_text(large_before)
    (repo/"docs/Instructions.md").write_text("# Instructions QA\nInspecter les deux worktrees sans modifier leurs fichiers. Une mention ne prouve pas une lecture.\n")
    git(repo,"init","-b","qa-base");git(repo,"add",".");git(repo,"commit","-m","Anonymous QA baseline")
    alpha=out/"worktrees/alpha";beta=out/"worktrees/beta";alpha.parent.mkdir()
    git(repo,"worktree","add","-b","qa-alpha",str(alpha));git(repo,"worktree","add","-b","qa-beta",str(beta))
    alpha_text=baseline.replace('"baseline"','"alpha current / recorded fixture patch"')
    beta_read=baseline.replace('"baseline"','"beta recorded read"')
    beta_current=baseline.replace('"baseline"','"beta current / manual fixture edit"')
    (alpha/"src/Same.swift").write_text(alpha_text)
    (beta/"src/Same.swift").write_text(beta_current)
    (alpha/"src/ManualOnly.swift").write_text('let manual = "manual edit with no Codex trace"\n')
    (alpha/"src/Large.swift").write_text(large_after)
    (alpha/"src/Unicode CRLF.swift").write_bytes('let sample = "café 東京"\r\n// tab\tkept\r\n'.encode())
    (alpha/"src/LongLine.swift").write_text('let long = "'+("anonyme "*1800)+'"\n')
    attachments=out/"attachments";attachments.mkdir()
    image=attachments/"local image.png";image.write_bytes(png())
    note=attachments/"provided note with spaces.md";note.write_text("# Document fourni de fixture\nComparer alpha et beta ; ne pas attribuer le diff manuel à Codex.\n")
    missing=attachments/"unavailable attachment.png"
    read_text=(alpha/"docs/Instructions.md").read_text()
    root=Stream()
    root.message("developer","Instruction enregistrée QA : préserver les versions, afficher les inconnues, ne lancer aucune commande depuis l’inspecteur.",ident="qa-developer-instruction")
    root.message("user",f"Session de qualification Alpha.\nFiles:\n- \"{note}\"\n- \"{image}\"\n- \"{missing}\"\nMy request:\nUne ressource externe est seulement référencée : https://example.invalid/qa/reference",extras=[{"type":"localImage","path":str(image)},{"type":"localImage","path":str(missing)},{"type":"input_image","image_url":"data:image/png;base64,"+base64.b64encode(image.read_bytes()).decode()}],ident="qa-user-supplied")
    root.message("assistant","Je lis les instructions Alpha et délègue la lecture du fichier homonyme Beta pour comparer les environnements. Ceci est une explication de fixture enregistrée.",ident="qa-recorded-explanation")
    root.call("qa-read-instructions","exec_command",{"cmd":"cat docs/Instructions.md","workdir":str(alpha)})
    root.result("qa-read-instructions",read_text)
    root.call("qa-spawn","spawn_agent",{"task_name":"beta-reader","message":"Lire src/Same.swift dans Beta, rendre le résultat et ses limites ; aucune écriture.","cwd":str(beta)},"agents")
    root.result("qa-spawn",encoded({"agent_id":CHILD,"task_name":"beta-reader"}).decode())
    root.call("qa-read-alpha","exec_command",{"cmd":"cat src/Same.swift","workdir":str(alpha)})
    root.result("qa-read-alpha",baseline)
    small_patch='*** Begin Patch\n*** Update File: src/Same.swift\n@@\n-    static let label = "baseline"\n+    static let label = "alpha current / recorded fixture patch"\n*** End Patch'
    root.patch("qa-patch-alpha",small_patch)
    root.patch_result("qa-patch-alpha","Success. Updated the following files:\nM src/Same.swift")
    root.patch("qa-patch-failed",'*** Begin Patch\n*** Update File: src/Absent.swift\n@@\n-old\n+new\n*** End Patch')
    root.patch_result("qa-patch-failed","Error: File not found: src/Absent.swift. Patch was not applied.")
    root.call("qa-shell-error","exec_command",{"cmd":"cat src/DoesNotExist.swift","workdir":str(beta)})
    root.result("qa-shell-error","Process exited with code 2\nError: fixture file is unavailable. No command was actually run to create this trace.")
    large_patch='*** Begin Patch\n*** Update File: src/Large.swift\n@@\n'+''.join('-'+line for line in large_before.splitlines(True))+''.join('+'+line for line in large_after.splitlines(True))+'*** End Patch'
    root.patch("qa-large-patch",large_patch);root.patch_result("qa-large-patch","Success. Updated src/Large.swift (synthetic recorded result).")
    long_output=''.join(f"anonymous output row {i:05d} · café 東京\n" for i in range(6500))
    root.call("qa-long-output","exec_command",{"cmd":"fixture long-output (record only)","workdir":str(alpha)})
    root.result("qa-long-output",long_output)
    root.call("qa-mcp-resource","read_resource",{"uri":"fixture://instructions","server":"anonymous-fixture"},"mcp")
    root.result("qa-mcp-resource","Recorded MCP result: inspect only; no server was contacted.")
    root.call("qa-wait-child","wait_agent",{"timeout_ms":10000},"agents")
    root.result("qa-wait-child",encoded({"agent_id":CHILD,"status":"completed"}).decode())
    child=Stream(start=700)
    child.message("user","Mission reçue : lecture du src/Same.swift Beta sans écriture.",ident="qa-child-mission")
    child.event("turn_context",{"turn_id":"qa-child-turn","cwd":str(beta)})
    child.call("qa-read-beta","exec_command",{"cmd":"cat src/Same.swift","workdir":str(beta)})
    child.result("qa-read-beta",beta_read)
    child.message("assistant","Résultat Beta enregistré. Les octets actuels peuvent différer après une édition manuelle ; la lecture ci-dessus est la preuve historique disponible.",ident="qa-child-answer")
    child.event("event_msg",{"type":"task_complete","last_agent_message":"Lecture Beta terminée dans le corpus de fixture."})
    other=Stream(start=2000)
    other.message("user","Session indépendante Beta, même dépôt mais aucun lien parent. Ne pas la rattacher à Alpha.",ident="qa-other-user")
    other.call("qa-other-read","exec_command",{"cmd":"cat src/Same.swift","workdir":str(beta)})
    other.result("qa-other-read",beta_current)
    other.message("assistant","Résultat indépendant de fixture.",ident="qa-other-answer")
    # Metadata, root+child native streams total exactly target records. Normalized UI counts are measured later.
    remaining=target-(len(root.records)+len(child.records)+2)
    if remaining<0:raise SystemExit("Target too small")
    for index in range(remaining):
        if index%137==0 and index+1<remaining:
            root.call(f"qa-background-call-{index}","exec_command",{"cmd":"printf 'anonymous background event'","workdir":str(alpha)})
        elif index%137==1:
            root.result(f"qa-background-call-{index-1}",f"Recorded anonymous background result {index}; no process ran.")
        else:root.message("assistant",f"Événement anonymisé {index:05d}. État de collecte, aucune action externe.",ident=f"qa-background-{index:05d}")
    home=out/"codex-home";sessions=home/"sessions/2026/10/01";sessions.mkdir(parents=True)
    commit=git(repo,"rev-parse","HEAD")
    def write(ident,cwd,stream,parent=None):
        meta={"id":ident,"session_id":parent or ident,"cwd":str(cwd),"cli_version":"0.159.2","source":"cli","git":{"branch":"qa-alpha" if cwd==alpha else "qa-beta","commit_hash":commit},"timestamp":stamp(0)}
        if parent:meta.update(parent_thread_id=parent,agent_path="/root/beta-reader",source={"subagent":{"thread_spawn":{"parent_thread_id":parent,"depth":1,"agent_path":"/root/beta-reader"}}})
        path=sessions/("rollout-2026-10-01T12-00-00-"+ident+".jsonl")
        data=b"\n".join(encoded(record) for record in [{"timestamp":stamp(0),"type":"session_meta","payload":meta}]+stream.records)+b"\n";path.write_bytes(data)
        return {"path":str(path),"sha256":digest(data),"bytes":len(data),"rawRecords":len(stream.records)+1}
    logs={ROOT:write(ROOT,alpha,root),CHILD:write(CHILD,beta,child,ROOT),OTHER:write(OTHER,beta,other)}
    expected={"familyRawRecordCount":target,"normalizedEventCountNotYetQualified":True,"agents":[ROOT,CHILD],"unrelatedRoot":OTHER,"toolCallIDs":{"alphaRead":"qa-read-alpha","betaRead":"qa-read-beta","patch":"qa-patch-alpha","failedPatch":"qa-patch-failed","shellError":"qa-shell-error","largePatch":"qa-large-patch","longOutput":"qa-long-output"},"providedMessageID":"qa-user-supplied","developerInstructionID":"qa-developer-instruction","longOutputUTF8Bytes":len(long_output.encode()),"longOutputSHA256":digest(long_output.encode()),"largePatchUTF8Bytes":len(large_patch.encode()),"sameRelativePath":"src/Same.swift","alphaCurrentSHA256":digest(alpha_text.encode()),"betaCurrentSHA256":digest(beta_current.encode()),"betaRecordedReadSHA256":digest(beta_read.encode()),"manualOnlyPath":str(alpha/"src/ManualOnly.swift"),"localImage":str(image),"localImageSHA256":digest(image.read_bytes()),"providedDocument":str(note),"missingAttachment":str(missing),"missingAttachmentExists":missing.exists(),"historicalVersions":"Only recorded command output/patch/attachment bytes; current files are not substituted."}
    manifest={"schemaVersion":1,"anonymous":True,"rootID":ROOT,"childID":CHILD,"otherRootID":OTHER,"home":str(home),"worktrees":{"alpha":str(alpha),"beta":str(beta)},"repository":str(repo),"baselineGitReference":commit,"rollouts":logs,"expected":expected,"lastRootTimestampMilliseconds":root.milliseconds-100,"generatorSHA256":digest(Path(__file__).read_bytes()),"noRealCodexSourcesOrAuthRead":True,"gitHooksDisabled":True,"allLogCommandsAreRecordedFixtureDataNeverExecuted":True}
    (out/"corpus-manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({"rootID":ROOT,"home":str(home),"familyRawRecords":target,"rootBytes":logs[ROOT]["bytes"],"manifest":str(out/"corpus-manifest.json")},ensure_ascii=False))

def append_live(out, partial=False):
    manifest=json.loads((out/"corpus-manifest.json").read_text());root=manifest["rootID"]
    stream=Stream(start=manifest["lastRootTimestampMilliseconds"]+100)
    sequence=len(manifest.get("appendReceipts",[]))+1
    stream.message("assistant",f"Nouvel événement direct anonymisé {sequence}.",ident=f"qa-live-{sequence}")
    stream.call(f"qa-live-call-{sequence}","exec_command",{"cmd":"fixture live trace only","workdir":manifest["worktrees"]["beta"]})
    stream.result(f"qa-live-call-{sequence}","Résultat disponible ; aucune commande réexécutée.")
    data=b"\n".join(encoded(record) for record in stream.records)+b"\n"
    path=Path(manifest["rollouts"][root]["path"])
    with path.open("ab") as handle:handle.write(data if not partial else data[:len(data)//2])
    receipt={"sequence":sequence,"writtenBytes":len(data) if not partial else len(data)//2,"complete":not partial,"firstID":f"qa-live-{sequence}","noCodexProcessTouched":True}
    manifest.setdefault("appendReceipts",[]).append(receipt);manifest["lastRootTimestampMilliseconds"]=stream.milliseconds-100
    (out/"corpus-manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n")
    if partial:(out/"pending-fixture-line.bin").write_bytes(data[len(data)//2:])
    print(json.dumps(receipt))

if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--output",required=True,type=Path);parser.add_argument("--events",type=int,default=12000);parser.add_argument("--append-live",action="store_true");parser.add_argument("--append-incomplete",action="store_true");parser.add_argument("--finish-incomplete",action="store_true");args=parser.parse_args()
    if args.finish_incomplete:
        pending=args.output/"pending-fixture-line.bin";manifest=json.loads((args.output/"corpus-manifest.json").read_text())
        with Path(manifest["rollouts"][ROOT]["path"]).open("ab") as handle:handle.write(pending.read_bytes())
        pending.unlink();print("Incomplete fixture tail finished; no real session touched.")
    elif args.append_live or args.append_incomplete:append_live(args.output,args.append_incomplete)
    else:create(args.output,args.events)
