import Foundation

/// The lifecycle of a single piece of content aimed at a single platform.
///
/// The brief (§9) specifies `idea → draft → review → approved → scheduled →
/// publishing → published`, plus `rejected`, `needsRevision`, `failed` and
/// `cancelled`. This adds one state the brief does not list:
/// `awaitingReconciliation`. See its doc comment for why — in short, without it
/// a lost HTTP response forces a choice between double-posting and losing the
/// post, and the brief (§14) explicitly requires handling that case.
public enum PublicationState: String, Codable, Sendable, CaseIterable, Hashable {
    /// The AI has proposed a content opportunity; no media or caption yet.
    case idea
    /// Media selected and caption generated; not yet shown for approval.
    case draft
    /// Presented to the user for approval.
    case review
    /// User approved the content. Not yet given a publish time.
    case approved
    /// Has a concrete future publish time; the scheduler owns it from here.
    case scheduled
    /// A worker has begun calling the platform API. Side effects may exist.
    case publishing
    /// Confirmed live on the platform, with a remote identifier recorded.
    case published

    /// The user declined this content. Terminal — regenerating creates a new row,
    /// so that rejection remains a durable training signal (§6 "Learning From Feedback").
    case rejected
    /// The user wants changes. Returns to the generator, keeping edit history.
    case needsRevision
    /// Publishing failed in a way we are confident produced no post.
    case failed
    /// Withdrawn before publishing, by the user or by a safeguard.
    case cancelled

    /// We called the platform and did not learn the outcome — timeout, dropped
    /// connection, or a 5xx after the request was accepted. The post may or may
    /// not be live.
    ///
    /// Nothing may re-publish from this state. A reconciliation job queries the
    /// platform for the idempotency key or recent media, then moves the row to
    /// `published` or `failed`. This is the state that prevents duplicate posts
    /// after a worker timeout (§14).
    case awaitingReconciliation

    /// No event can move the row out of these.
    public var isTerminal: Bool {
        switch self {
        case .published, .rejected, .cancelled:
            return true
        case .idea, .draft, .review, .approved, .scheduled, .publishing,
             .needsRevision, .failed, .awaitingReconciliation:
            return false
        }
    }

    /// True when the platform may already hold a post for this row, so no code
    /// path may issue another publish call without first reconciling.
    ///
    /// `failed` is deliberately excluded: it means we established that no post
    /// exists. A failure we are *unsure* about must be `awaitingReconciliation`.
    public var mayHaveRemoteSideEffects: Bool {
        switch self {
        case .publishing, .published, .awaitingReconciliation:
            return true
        case .idea, .draft, .review, .approved, .scheduled, .rejected,
             .needsRevision, .failed, .cancelled:
            return false
        }
    }
}
