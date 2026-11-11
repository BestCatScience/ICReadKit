/// Moves command APDUs to a card and brings the responses back.
///
/// Core NFC is one implementation; tests and the demo card are others, so the
/// reading logic never depends on a phone or a real card. Only ``CommandAPDU``
/// values reach a transport, and those can only be SELECT or READ BINARY.
protocol CardTransport: Sendable {
    func transmit(_ command: CommandAPDU) async throws(CardReadError) -> ResponseAPDU
}
