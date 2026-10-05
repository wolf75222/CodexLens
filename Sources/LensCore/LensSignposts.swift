import Foundation
import os

/// Static interval names only. Paths, prompts, search terms and recorded content
/// never enter the system log.
public enum LensSignposts {
    private static let signposter = OSSignposter(subsystem: "fr.codexlens.inspector", category: .pointsOfInterest)

    public static func begin(_ name: StaticString) -> Span { Span(name: name) }

    public final class Span: @unchecked Sendable {
        private let name: StaticString
        private let state: OSSignpostIntervalState
        private let lock = NSLock()
        private var ended = false

        fileprivate init(name: StaticString) {
            self.name = name
            state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        }

        /// Safe for cancellation paths as well as successful completion.
        public func end() {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            lock.unlock()
            signposter.endInterval(name, state)
        }

        deinit { end() }
    }
}
