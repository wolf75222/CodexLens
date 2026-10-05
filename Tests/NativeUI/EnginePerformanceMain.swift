import Foundation
import LensCore

/// Synthetic rollouts only. No Codex app/server/model, real session or auth.
@main struct EnginePerformanceMain {
    static func main() async {
        do { try await run() }
        catch { fputs("ENGINE_PERF_FAILED: \(error)\n",stderr); exit(1) }
    }
    static func run() async throws {
        let args=CommandLine.arguments
        func value(_ key: String) throws -> String {
            guard let index=args.firstIndex(of:key),index+1<args.count else { throw failure("Missing argument \(key)") }; return args[index+1]
        }
        let output=URL(fileURLWithPath:try value("--output"))
        let sourceLabel=try value("--source-label")
        let pairCount=10_000
        let cycles = args.firstIndex(of:"--cycles").flatMap { $0+1<args.count ? Int(args[$0+1]) : nil } ?? 3
        guard (1...3).contains(cycles) else { throw failure("Cycles must be1...3") }
        let rootID="aaaaaaaa-0000-4000-8000-000000000001"
        let base=output.appendingPathComponent("synthetic-engine-fixture")
        let home=base.appendingPathComponent("codex-home")
        let environment=base.appendingPathComponent("environment")
        let sessions=home.appendingPathComponent("sessions/2026/10/02")
        try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:environment,withIntermediateDirectories:true)
        let rollout=sessions.appendingPathComponent("rollout-2026-10-02T00-00-00-"+rootID+".jsonl")
        func encoded(_ type:String,_ payload:[String:Any]) throws -> Data {
            var data=try JSONSerialization.data(withJSONObject:["timestamp":"2026-10-02T00:00:00.000Z","type":type,"payload":payload],options:[.sortedKeys]);data.append(10);return data
        }
        var bytes=try encoded("session_meta",["id":rootID,"cwd":environment.path,"source":"cli","cli_version":"0.159.2"])
        for index in 0..<pairCount {
            let callID=String(format:"call%05d",index)
            let arguments=try JSONSerialization.data(withJSONObject:["request":String(format:"needle%05d",index)],options:[.sortedKeys])
            bytes.append(try encoded("response_item",["type":"function_call","namespace":"fixture","name":"record","call_id":callID,"arguments":String(decoding:arguments,as:UTF8.self)]))
            bytes.append(try encoded("response_item",["type":"function_call_output","call_id":callID,"output":"recorded-result-\(index)"]))
        }
        try bytes.write(to:rollout)
        let ready:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"fixturePairCount":pairCount,"fixtureBytes":bytes.count,"sourceLabel":sourceLabel,"realSessionRead":false,"modelRequests":0,"networkDeniedByOS":true]
        try write(ready,to:output.appendingPathComponent("engine-ready.json"))
        print("ENGINE_PERF_READY pid=\(ProcessInfo.processInfo.processIdentifier)");fflush(stdout)
        if !args.contains("--run-now") {
            let trigger=output.appendingPathComponent("engine-trigger")
            while !FileManager.default.fileExists(atPath:trigger.path) { try await Task.sleep(nanoseconds:100_000_000) }
        }
        let clock=ContinuousClock()
        var observations:[[String:Any]]=[]
        var last:SessionSnapshot?
        var lastEngine:SessionEngine?
        for index in 0..<cycles {
            let engine=SessionEngine(home:home,cacheDirectory:base.appendingPathComponent("cache-\(index)"))
            let start=clock.now
            let snapshot=try await engine.open(id:rootID)
            let duration=ms(start.duration(to:clock.now))
            let calls=snapshot.events.filter{$0.kind == .toolCall}
            let results=snapshot.events.filter{$0.kind == .toolResult}
            let byID=Dictionary(uniqueKeysWithValues:snapshot.events.map{($0.id,$0)})
            guard calls.count == pairCount, results.count == pairCount,
                calls.allSatisfy({call in guard let id=call.relatedEventID,let result=byID[id] else{return false};return result.relatedEventID == call.id && result.callID == call.callID}) else { throw failure("Lost call/result pairing") }
            observations.append(["action":"cold_open_empty_index","cycle":index,"milliseconds":duration,"events":snapshot.events.count,"calls":calls.count,"results":results.count])
            last=snapshot;lastEngine=engine
            print("ENGINE_PERF_COLD cycle=\(index) milliseconds=\(duration)");fflush(stdout)
        }
        guard let engine=lastEngine,var snapshot=last else{throw failure("No snapshot")}
        for index in 0..<cycles {
            let start=clock.now;snapshot=try await engine.open(id:rootID)
            let openMS=ms(start.duration(to:clock.now))
            observations.append(["action":"warm_open","cycle":index,"milliseconds":openMS])
            print("ENGINE_PERF_WARM cycle=\(index) milliseconds=\(openMS)");fflush(stdout)
            try write(["sourceLabel":sourceLabel,"observations":observations,"finalSequenceCompleted":false],to:output.appendingPathComponent("engine-stage-report.json"))
            let query=String(format:"needle%05d",pairCount-1)
            let searchStart=clock.now
            let matches=try await engine.search(query:query,snapshot:snapshot)
            let searchMS=ms(searchStart.duration(to:clock.now))
            guard matches.contains(where:{id in snapshot.events.contains{$0.id == id && $0.callID == String(format:"call%05d",pairCount-1)}}) else{throw failure("Recorded arguments search lost target")}
            observations.append(["action":"recorded_search","cycle":index,"milliseconds":searchMS,"matchCount":matches.count])
            print("ENGINE_PERF_SEARCH cycle=\(index) milliseconds=\(searchMS)");fflush(stdout)
            try write(["sourceLabel":sourceLabel,"observations":observations,"finalSequenceCompleted":false],to:output.appendingPathComponent("engine-stage-report.json"))
            guard let event=snapshot.events.first(where:{$0.kind == .toolCall && $0.callID == String(format:"call%05d",pairCount-1)}) else{throw failure("Missing final call")}
            let detailStart=clock.now;let detail=try await engine.detail(for:event)
            guard detail.arguments.contains(query),detail.output.contains("recorded-result-9999") else{throw failure("Detail detached from recorded result")}
            observations.append(["action":"paired_detail","cycle":index,"milliseconds":ms(detailStart.duration(to:clock.now))])
        }
        let report:[String:Any]=["schemaVersion":1,"sourceLabel":sourceLabel,"fixturePairCount":pairCount,"fixtureBytes":bytes.count,"observations":observations,"functionalChecksPassed":true,"realSessionRead":false,"modelRequests":0,"networkDeniedByOS":true,"measurementContract":"ContinuousClock wall. Generation excluded. Cold means fresh engine and empty own cache, not OS disk cache cold. Warm repeats same engine/cache. One to three observations per category as specified; no statistical confidence claim."]
        try write(report,to:output.appendingPathComponent("engine-report.json"))
        print("ENGINE_PERF_COMPLETE")
    }
    static func ms(_ value:Duration)->Double{let c=value.components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15}
    static func failure(_ text:String)->NSError{NSError(domain:"CodexLensEnginePerf",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
    static func write(_ value:[String:Any],to url:URL)throws{try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)}
}
