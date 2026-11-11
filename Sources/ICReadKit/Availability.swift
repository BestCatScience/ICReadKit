import Foundation

/// Whether this app on this device can read a card at all.
///
/// Check this before showing a read button. A missing Info.plist key would
/// otherwise surface only as a vague Core NFC error after the sheet opens.
public enum Availability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    public enum Reason: Equatable, Sendable {
        /// The device has no NFC reader, or this is the simulator.
        case readingUnsupported
        /// The host app's Info.plist has no `NFCReaderUsageDescription`.
        case missingUsageDescription
        /// The host app's Info.plist does not list the JPKI application identifier
        /// under `com.apple.developer.nfc.readersession.iso7816.select-identifiers`.
        case missingApplicationIdentifier
    }

    static let usageDescriptionKey = "NFCReaderUsageDescription"
    static let selectIdentifiersKey = "com.apple.developer.nfc.readersession.iso7816.select-identifiers"
    /// The JPKI application identifier as Info.plist spells it.
    static let jpkiIdentifier = JPKI.applicationIdentifier.map { String(format: "%02X", $0) }.joined()

    /// Checks the host app's Info.plist first, so a configuration mistake is reported even on the simulator.
    static func check(infoDictionary: [String: Any]?, readingSupported: Bool) -> Availability {
        let info = infoDictionary ?? [:]
        let usage = info[usageDescriptionKey] as? String ?? ""
        guard !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(.missingUsageDescription)
        }
        let identifiers = (info[selectIdentifiersKey] as? [String] ?? []).map { $0.uppercased() }
        guard identifiers.contains(jpkiIdentifier) else {
            return .unavailable(.missingApplicationIdentifier)
        }
        return readingSupported ? .available : .unavailable(.readingUnsupported)
    }
}
