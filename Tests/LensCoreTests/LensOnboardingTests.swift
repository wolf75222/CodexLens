import Foundation
import XCTest
@testable import LensCore

final class LensOnboardingTests: XCTestCase {
    func testTopicsHaveStableIdentitiesAndBoundedProgression() {
        let expected: [LensGuideTopic] = [.openSession, .activity, .proofs, .investigation, .shortcuts]
        XCTAssertEqual(LensGuideTopic.allCases, expected)
        XCTAssertEqual(expected.map(\.id), ["openSession", "activity", "proofs", "investigation", "shortcuts"])
        XCTAssertEqual(Set(expected.map(\.id)).count, expected.count)
        XCTAssertNil(expected.first?.previous)
        XCTAssertNil(expected.last?.next)

        for (index, topic) in expected.enumerated() {
            XCTAssertEqual(topic.previous, index > 0 ? expected[index - 1] : nil)
            XCTAssertEqual(topic.next, index + 1 < expected.count ? expected[index + 1] : nil)
            if let next = topic.next { XCTAssertEqual(next.previous, topic) }
            if let previous = topic.previous { XCTAssertEqual(previous.next, topic) }
        }
    }

    func testSharedStateClaimsAutomaticGuideForOnlyOneWindow() async {
        await MainActor.run {
            let suite = "LensOnboardingTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let shared = LensOnboardingState(defaults: defaults)

            let windowClaims = (0..<8).map { _ in shared.shouldPresentAutomatically() }
            XCTAssertEqual(windowClaims, [true, false, false, false, false, false, false, false])
            XCTAssertNil(defaults.object(forKey: LensOnboardingState.preferenceKey),
                         "Presenting alone must not silently dismiss the guide for future launches")
        }
    }

    func testSkipDismissalPersistsAcrossRestart() async {
        await MainActor.run {
            let suite = "LensOnboardingTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let firstLaunch = LensOnboardingState(defaults: defaults)
            XCTAssertTrue(firstLaunch.shouldPresentAutomatically())
            firstLaunch.dismiss()
            XCTAssertTrue(defaults.bool(forKey: LensOnboardingState.preferenceKey))
            XCTAssertFalse(firstLaunch.shouldPresentAutomatically())

            let restartedDefaults = UserDefaults(suiteName: suite)!
            XCTAssertFalse(LensOnboardingState(defaults: restartedDefaults).shouldPresentAutomatically())
        }
    }

    func testFinishOrCloseBeforeAutomaticClaimAlsoPersists() async {
        await MainActor.run {
            let suite = "LensOnboardingTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let state = LensOnboardingState(defaults: defaults)
            state.dismiss()
            state.dismiss()

            XCTAssertFalse(state.shouldPresentAutomatically())
            XCTAssertFalse(LensOnboardingState(defaults: UserDefaults(suiteName: suite)!).shouldPresentAutomatically())
            XCTAssertTrue(defaults.bool(forKey: LensOnboardingState.preferenceKey))
        }
    }

    func testInterruptedLaunchDoesNotPersistDismissal() async {
        await MainActor.run {
            let suite = "LensOnboardingTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            XCTAssertTrue(LensOnboardingState(defaults: defaults).shouldPresentAutomatically())

            let restarted = LensOnboardingState(defaults: UserDefaults(suiteName: suite)!)
            XCTAssertTrue(restarted.shouldPresentAutomatically())
            XCTAssertFalse(restarted.shouldPresentAutomatically())
        }
    }
}
