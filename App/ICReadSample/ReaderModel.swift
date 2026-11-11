import ICReadKit
import Observation

/// The sample host app's screen state. It shows how a host app consumes the kit:
/// check availability first, treat cancel as a normal exit, and word each error itself.
@MainActor
@Observable
final class ReaderModel {
    enum Phase: Equatable {
        case idle
        case reading
        case read(CertificateSummary)
        case failed(CardReadError)
    }

    private(set) var phase: Phase = .idle
    var demoCard: DemoCard = .valid
    /// True on a device without an NFC reader, such as the simulator, so every screen can still be shown.
    let usesDemoCards: Bool
    let availability: Availability

    init(availability: Availability = CardReader().availability()) {
        self.availability = availability
        usesDemoCards = availability == .unavailable(.readingUnsupported)
    }

    var canRead: Bool { (usesDemoCards || availability == .available) && phase != .reading }

    func read() async {
        phase = .reading
        let reader = CardReader(source: usesDemoCards ? .demo(demoCard) : .nfc)
        do throws(CardReadError) {
            phase = .read(try await reader.readCertificateSummary())
        } catch .cancelled {
            phase = .idle
        } catch {
            phase = .failed(error)
        }
    }

    /// The kit returns reasons; the host app decides the words.
    static func message(for error: CardReadError) -> String {
        switch error {
        case .unavailable(.readingUnsupported): "この端末では NFC でカードを読めません。"
        case .unavailable(.missingUsageDescription): "アプリの設定に NFC の利用目的がありません（開発者向け）。"
        case .unavailable(.missingApplicationIdentifier): "アプリの設定に読み取るカードの種類がありません（開発者向け）。"
        case .cancelled: "読み取りを中止しました。"
        case .timeout: "カードが見つかりませんでした。もう一度お試しください。"
        case .connectionLost: "読み取り中にカードが離れました。動かさずにもう一度当ててください。"
        case .unsupportedCard: "このカードには対応していません。マイナンバーカードを当ててください。"
        case .cardRejected(let statusWord): "カードが読み取りを受け付けませんでした（\(String(format: "%04X", statusWord))）。"
        case .malformedCertificate: "カードの証明書を読み取れませんでした。"
        case .system(let code): "読み取りに失敗しました（\(code)）。"
        // The kit may add reasons in a later version without breaking this app.
        @unknown default: "読み取れませんでした。"
        }
    }

    static func message(for reason: Availability.Reason) -> String {
        message(for: .unavailable(reason))
    }
}
