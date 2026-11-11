/// One step of a read, for measuring where people give up.
///
/// A host app forwards these to its own analytics (Datadog, Firebase and so on).
/// They carry no card data: no certificate, no serial number, no name.
///
/// The funnel is `started` → `cardDetected` → `finished(.read)`. A read that
/// finishes `cancelled` or `failed(.timeout)` without `cardDetected` is someone
/// who never managed to hold the card; one with `cardDetected` and
/// `failed(.connectionLost)` held it but moved it too soon.
public enum CardReadEvent: Equatable, Sendable {
    /// The NFC sheet opened (or a demo read began).
    case started(demo: Bool)
    /// A card came into range. `attempt` counts detections in this sheet, so a
    /// second detection means the card was moved away and back.
    case cardDetected(attempt: Int)
    /// The read ended. `duration` runs from `started`.
    case finished(Outcome, duration: Duration)

    public enum Outcome: Equatable, Sendable {
        case read(CertificateSummary.Validity)
        case cancelled
        case failed(CardReadError)
    }
}

/// Where the reader sends its events. Calls arrive on an arbitrary thread.
public typealias CardReadEventHandler = @Sendable (CardReadEvent) -> Void
