import XCTest
import Foundation
import Darwin
@testable import LensCore

final class CodexAppServerTransportTests: XCTestCase {
    func testFragmentedMessagesAndDefaultServerRequestRefusal() async throws {
        let transport = fixture(#"""
import json, os, sys, time
request = json.loads(sys.stdin.readline())
sys.stderr.write('discarded fixture diagnostics\n' * 4096)
sys.stderr.flush()
line = json.dumps({'method':'fixture/progress','params':{'text':'anonymous fixture'}}).encode() + b'\n'
os.write(1, line[:15])
time.sleep(0.01)
os.write(1, line[15:])
print(json.dumps({'id':request['id'],'result':{'echo':request.get('params')}}), flush=True)
print(json.dumps({'id':7,'method':'fixture/unsupported','params':{}}), flush=True)
reply = json.loads(sys.stdin.readline())
print(json.dumps({'method':'fixture/denied','params':{'id':reply['id'],'code':reply['error']['code']}}), flush=True)
sys.stdin.read()
"""#)
        try await transport.start()
        let stream = Task { () throws -> [CodexAppServerNotification] in
            var received: [CodexAppServerNotification] = []
            for try await notification in transport.notifications {
                received.append(notification)
                if received.count == 2 { return received }
            }
            return received
        }
        let result = try await transport.request(method: "fixture/echo", params: Data(#"{"value":42}"#.utf8))
        let object = try json(result)
        XCTAssertEqual((object["echo"] as? [String: Any])?["value"] as? Int, 42)
        let messages = try await stream.value
        XCTAssertEqual(messages.map(\.method), ["fixture/progress", "fixture/denied"])
        let denied = try json(XCTUnwrap(messages.last?.params))
        XCTAssertEqual(denied["id"] as? Int, 7)
        XCTAssertEqual(denied["code"] as? Int, -32601)
        await transport.close()
    }

    func testTimeoutDoesNotResolveAnotherRequestWithALateResponse() async throws {
        let transport = fixture(#"""
import json, sys, time
first = json.loads(sys.stdin.readline())
time.sleep(0.12)
print(json.dumps({'id':first['id'],'result':{'value':'late'}}), flush=True)
second = json.loads(sys.stdin.readline())
print(json.dumps({'id':second['id'],'result':{'value':'second'}}), flush=True)
sys.stdin.read()
"""#)
        try await transport.start()
        do {
            _ = try await transport.request(method: "fixture/first", timeoutSeconds: 0.03)
            XCTFail("A timed out request must fail")
        } catch {
            XCTAssertEqual(error as? CodexAppServerTransportError, .timeout(method: "fixture/first"))
        }
        let result = try await transport.request(method: "fixture/second", timeoutSeconds: 2)
        XCTAssertEqual(try json(result)["value"] as? String, "second")
        await transport.close()
    }

    func testAChildNotReadingStdinCannotBlockTimeoutOrClose() async throws {
        let transport = fixture("import time\ntime.sleep(60)")
        try await transport.start()
        let params = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "x", count: 400_000)])
        do {
            _ = try await transport.request(method: "fixture/blocked-input", params: params, timeoutSeconds: 0.05)
            XCTFail("A full child input pipe must still time out")
        } catch {
            XCTAssertEqual(error as? CodexAppServerTransportError, .timeout(method: "fixture/blocked-input"))
        }
        await transport.close()
    }

    func testEOFWithAPartialResponseFailsEvenAfterExitZero() async throws {
        let transport = fixture(#"""
import sys
sys.stdin.readline()
sys.stdout.write('{"id":')
sys.stdout.flush()
"""#)
        try await transport.start()
        do {
            _ = try await transport.request(method: "fixture/eof")
            XCTFail("EOF cannot complete a pending request")
        } catch {
            XCTAssertEqual(error as? CodexAppServerTransportError, .transportClosed)
        }
        await transport.close()
    }

    func testRPCErrorPreservesCodeWithoutForwardingDiagnosticData() async throws {
        let transport = fixture(#"""
import json, sys
request = json.loads(sys.stdin.readline())
print(json.dumps({'id':request['id'],'error':{'code':-32601,'message':'Fixture failure.','data':{'privateDiagnostic':'not surfaced'}}}), flush=True)
sys.stdin.read()
"""#)
        try await transport.start()
        do {
            _ = try await transport.request(method: "fixture/error")
            XCTFail("RPC errors must fail the matching request")
        } catch {
            XCTAssertEqual(error as? CodexAppServerTransportError, .rpc(code: -32601, message: "Fixture failure."))
        }
        await transport.close()
    }

    func testInvalidAndOversizedOutputFailsClosed() async throws {
        for (output, limit, expected) in [("not JSON", 1024, CodexAppServerTransportError.invalidMessage),
                                          (String(repeating: "x", count: 300), 128, .lineTooLarge)] {
            let encoded = try JSONSerialization.data(withJSONObject: output, options: .fragmentsAllowed)
            let literal = String(decoding: encoded, as: UTF8.self)
            let transport = fixture("import sys\nsys.stdin.readline()\nprint(\(literal), flush=True)\nsys.stdin.read()", maximumLineBytes: limit)
            try await transport.start()
            do {
                _ = try await transport.request(method: "fixture/invalid")
                XCTFail("Malformed output must fail")
            } catch { XCTAssertEqual(error as? CodexAppServerTransportError, expected) }
            await transport.close()
        }
    }

    func testNotificationsOverflowFailsInsteadOfLosingCompletion() async throws {
        let transport = fixture(#"""
import json, sys
sys.stdin.readline()
for i in range(600):
    print(json.dumps({'method':'fixture/flood','params':{'index':i}}), flush=True)
sys.stdin.read()
"""#)
        try await transport.start()
        do {
            _ = try await transport.request(method: "fixture/flood")
            XCTFail("Overflow must fail instead of silently dropping events")
        } catch { XCTAssertEqual(error as? CodexAppServerTransportError, .backpressure) }
        await transport.close()
    }

    func testCancellationAndCloseReapAChildThatIgnoresTermination() async throws {
        let transport = fixture(#"""
import json, os, signal, sys
signal.signal(signal.SIGTERM, signal.SIG_IGN)
request = json.loads(sys.stdin.readline())
print(json.dumps({'id':request['id'],'result':{'pid':os.getpid()}}), flush=True)
sys.stdin.readline()
while True:
    signal.pause()
"""#)
        try await transport.start()
        let result = try await transport.request(method: "fixture/pid")
        let pid = try XCTUnwrap(try json(result)["pid"] as? Int32)
        let pending = Task { try await transport.request(method: "fixture/cancel") }
        try await Task.sleep(nanoseconds: 20_000_000)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancellation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        await transport.close()
        await transport.close()
        errno = 0
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testExplicitServerHandlerCanReturnAResultWithoutBlockingReads() async throws {
        let transport = fixture(#"""
import json, sys
request = json.loads(sys.stdin.readline())
print(json.dumps({'id':'fixture-server-id','method':'fixture/client','params':{'value':9}}), flush=True)
reply = json.loads(sys.stdin.readline())
print(json.dumps({'id':request['id'],'result':reply['result']}), flush=True)
sys.stdin.read()
"""#, serverRequestHandler: { request in
            XCTAssertEqual(request.method, "fixture/client")
            return .result(Data(#"{"value":9}"#.utf8))
        })
        try await transport.start()
        let result = try await transport.request(method: "fixture/handler")
        XCTAssertEqual(try json(result)["value"] as? Int, 9)
        await transport.close()
    }

    private func fixture(_ source: String, maximumLineBytes: Int = 1_048_576,
                         serverRequestHandler: CodexAppServerTransport.ServerRequestHandler? = nil) -> CodexAppServerTransport {
        CodexAppServerTransport(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                arguments: ["-u", "-c", source],
                                environment: ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"],
                                maximumLineBytes: maximumLineBytes,
                                requestTimeoutSeconds: 3,
                                serverRequestHandler: serverRequestHandler)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
