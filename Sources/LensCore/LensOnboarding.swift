import Foundation

/// Shared topic identities for the first-run guide and the help page.
/// The order is part of the guide's navigation contract.
public enum LensGuideTopic: String, CaseIterable, Identifiable, Sendable {
    case openSession
    case activity
    case proofs
    case investigation
    case shortcuts

    public var id: String { rawValue }

    public var previous: LensGuideTopic? {
        switch self {
        case .openSession: nil
        case .activity: .openSession
        case .proofs: .activity
        case .investigation: .proofs
        case .shortcuts: .investigation
        }
    }

    public var next: LensGuideTopic? {
        switch self {
        case .openSession: .activity
        case .activity: .proofs
        case .proofs: .investigation
        case .investigation: .shortcuts
        case .shortcuts: nil
        }
    }
}

/// One app-wide instance arbitrates automatic presentation between windows.
/// Only explicit dismissal persists; an interrupted launch can show the guide again.
@MainActor
public final class LensOnboardingState {
    public static let preferenceKey = "lens.onboarding.v1.dismissed"

    private let defaults: UserDefaults
    private var automaticPresentationClaimed = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Claims automatic presentation once for this instance's lifetime.
    /// Replaying the guide from Help is independent of this claim.
    public func shouldPresentAutomatically() -> Bool {
        guard !automaticPresentationClaimed,
              !defaults.bool(forKey: Self.preferenceKey) else { return false }
        automaticPresentationClaimed = true
        return true
    }

    /// Used by Skip, Finish, and the guide window's close action.
    public func dismiss() {
        automaticPresentationClaimed = true
        defaults.set(true, forKey: Self.preferenceKey)
    }
}
