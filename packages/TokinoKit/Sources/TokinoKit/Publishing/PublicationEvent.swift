import Foundation

/// Everything that can move a publication through its lifecycle.
///
/// Modelling transitions as events rather than letting callers assign states
/// directly is what makes the state machine auditable: every change has a named
/// cause, and `PublicationStateMachine` is the single place that decides whether
/// a cause is legal from a given state.
public enum PublicationEvent: Sendable, Hashable {
    /// Media and caption have been generated for an idea.
    case drafted
    /// Submitted for the user's approval.
    case submittedForReview
    /// The user approved the content.
    case approved
    /// The user declined. Terminal.
    case rejected(reason: String?)
    /// The user asked for changes.
    case revisionRequested(note: String?)
    /// Revisions are done; back for another look.
    case revised
    /// A publish time was set.
    case scheduled(at: Date)
    /// The schedule was changed while still pending.
    case rescheduled(at: Date)
    /// Returned to approved, dropping its publish time.
    case unscheduled
    /// A worker has claimed the row and is about to call the platform.
    /// Carries the idempotency key the platform call will use.
    case publishStarted(idempotencyKey: String)
    /// The platform confirmed the post, returning its identifier.
    case publishSucceeded(remoteID: String)
    /// The call failed and we are confident no post was created.
    case publishFailed(error: PublishFailure)
    /// The call's outcome is unknown. Routes to `awaitingReconciliation`.
    case publishOutcomeUnknown(idempotencyKey: String)
    /// Reconciliation found a live post.
    case reconciledAsPublished(remoteID: String)
    /// Reconciliation established that no post exists.
    case reconciledAsFailed(error: PublishFailure)
    /// A failed publication is being retried.
    case retryRequested
    /// Withdrawn before publishing.
    case cancelled(reason: String?)
}

/// Why a publish attempt failed, and whether retrying could plausibly help.
public struct PublishFailure: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// Network, 5xx, or platform-side transient fault. Retry.
        case transient
        /// Credentials expired or were revoked. Needs user re-auth, not a retry.
        case authenticationExpired
        /// We hit the platform's publishing quota. Retry after the window.
        case rateLimited
        /// The platform rejected the content itself (bad aspect ratio, caption
        /// too long, unsupported format). Retrying the same payload is futile.
        case contentRejected
        /// A bug or unexpected response shape on our side.
        case internalError
    }

    public let kind: Kind
    public let message: String
    /// Earliest sensible retry, when the platform tells us (e.g. rate limits).
    public let retryAfter: Date?

    public init(kind: Kind, message: String, retryAfter: Date? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
    }

    /// Whether the scheduler should attempt this again on its own.
    ///
    /// `authenticationExpired` is not retryable: it needs the user to reconnect
    /// the account, so retrying would burn attempts and could trip platform
    /// abuse heuristics.
    public var isRetryable: Bool {
        switch kind {
        case .transient, .rateLimited:
            return true
        case .authenticationExpired, .contentRejected, .internalError:
            return false
        }
    }
}
