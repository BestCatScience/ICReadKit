import Foundation
import ICReadKit
import Observation
import Security

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

    enum WalletPhase: Equatable {
        case checking
        case unsupportedOS
        case unavailable
        case ready
        case requesting
        case received(bytes: Int)
        case failed(WalletIDError)
    }

    private(set) var walletPhase: WalletPhase = .checking
    /// Ask for the least a service needs: the name and whether the holder is an adult, not the birth date.
    static let walletElements: Set<WalletIDElement> = [.name, .ageAtLeast(18)]
    /// The merchant identifier the identity entitlement is tied to. The sample has no entitlement,
    /// so on a real iPhone Wallet answers "cannot request" until Apple grants one.
    static let merchantIdentifier = "merchant.com.bestcatscience.icreadsample"
    /// The latest events, newest first. In a real app these go to analytics instead.
    private(set) var events: [CardReadEvent] = []
    private(set) var funnel = Funnel()

    /// Counts for the read funnel, kept only on this device.
    struct Funnel: Equatable {
        var started = 0
        var cardDetected = 0
        var read = 0

        /// The share of reads that never produced a certificate.
        var abandonRate: Double? { started == 0 ? nil : Double(started - read) / Double(started) }
    }
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
        let reader = CardReader(source: usesDemoCards ? .demo(demoCard) : .nfc) { event in
            Task { @MainActor in self.record(event) }
        }
        do throws(CardReadError) {
            phase = .read(try await reader.readCertificateSummary())
        } catch .cancelled {
            phase = .idle
        } catch {
            phase = .failed(error)
        }
    }

    private func record(_ event: CardReadEvent) {
        events.insert(event, at: 0)
        events = Array(events.prefix(6))
        switch event {
        case .started: funnel.started += 1
        case .cardDetected(let attempt) where attempt == 1: funnel.cardDetected += 1
        case .finished(.read, _): funnel.read += 1
        default: break
        }
    }

    static func describe(_ event: CardReadEvent) -> String {
        switch event {
        case .started(let demo): demo ? "開始（デモ）" : "開始"
        case .cardDetected(let attempt): attempt == 1 ? "カード検出" : "カード再検出（\(attempt) 回目）"
        case .finished(let outcome, let duration):
            "終了：\(describe(outcome))（\(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))）"
        @unknown default: "不明なイベント"
        }
    }

    private static func describe(_ outcome: CardReadEvent.Outcome) -> String {
        switch outcome {
        case .read(let validity): validity == .valid ? "読み取り（有効）" : "読み取り（有効でない）"
        case .cancelled: "中止"
        case .failed(let error): "失敗・\(String(describing: error))"
        @unknown default: "不明"
        }
    }

    func checkWallet() async {
        guard #available(iOS 18.0, *) else {
            walletPhase = .unsupportedOS
            return
        }
        let availability = await WalletIDReader(merchantIdentifier: Self.merchantIdentifier).availability(for: Self.walletElements)
        walletPhase = availability == .available ? .ready : .unavailable
    }

    func requestWallet() async {
        guard #available(iOS 18.0, *) else { return }
        walletPhase = .requesting
        // A real app asks its server for the nonce and sends the encrypted response back to it.
        // The sample makes the nonce here only to show the call.
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else {
            walletPhase = .failed(.invalidNonce)
            return
        }
        do throws(WalletIDError) {
            let presentation = try await WalletIDReader(merchantIdentifier: Self.merchantIdentifier)
                .requestPresentation(of: Self.walletElements, nonce: nonce)
            walletPhase = .received(bytes: presentation.encryptedData.count)
        } catch .cancelled {
            walletPhase = .ready
        } catch {
            walletPhase = .failed(error)
        }
    }

    static func message(for phase: WalletPhase) -> String {
        switch phase {
        case .checking: "確認しています…"
        case .unsupportedOS: "iOS 18 以降で使えます。"
        case .unavailable: "この端末では、Wallet のマイナンバーカードを使えません。Wallet にカードがない、iOS 18.5 より前、またはアプリに Apple の許可（entitlement）がない場合です。"
        case .ready: "Wallet のマイナンバーカードで、氏名と 18 歳以上かどうかを確認できます。"
        case .requesting: "Wallet で確認しています…"
        case .received(let bytes): "暗号化されたデータ（\(bytes) バイト）を受け取りました。中身はサーバーで復号して検証します。"
        case .failed(let error): message(for: error)
        }
    }

    static func message(for error: WalletIDError) -> String {
        switch error {
        case .unavailable: "この端末では Wallet で確認できません。カードを読み取る方法をお使いください。"
        case .cancelled: "確認を中止しました。"
        case .networkUnavailable: "通信できません。オンラインでもう一度お試しください。"
        case .invalidNonce: "確認の準備に失敗しました（開発者向け：nonce）。"
        case .invalidRequest: "確認する項目の指定が正しくありません（開発者向け）。"
        case .busy: "別の確認が進行中です。終わってからお試しください。"
        case .regionNotSupported: "この地域の身分証には対応していません。"
        case .system(let code): "確認に失敗しました（\(code)）。"
        @unknown default: "確認できませんでした。"
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
