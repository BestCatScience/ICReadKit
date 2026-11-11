/// Why a read did not produce a certificate. Every case says what the host app can do next.
///
/// The kit never crashes the host app over a card: anything unexpected from the
/// card or the system arrives here instead.
public enum CardReadError: Error, Equatable, Sendable {
    /// Reading is impossible here. Show the reason; retrying will not help.
    case unavailable(Availability.Reason)
    /// The person closed the NFC sheet. Treat it as a normal exit, not a failure.
    case cancelled
    /// No card was held to the phone before the system timed out. Offer to try again.
    case timeout
    /// The card moved away mid-read. Ask the person to hold it still and try again.
    case connectionLost
    /// The card answered but has no public key application. It is probably another kind of card.
    case unsupportedCard
    /// The card refused a command. The status word is for support logs, not for the person.
    case cardRejected(statusWord: UInt16)
    /// The card returned something that is not a certificate the kit can read.
    case malformedCertificate
    /// Core NFC reported an error the kit does not map. The code is NFCReaderError.Code.
    case system(code: Int)
}
