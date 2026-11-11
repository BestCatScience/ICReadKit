import ICReadKit
import SwiftUI

struct ReaderScreen: View {
    @State private var model = ReaderModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("マイナンバーカードの利用者証明用電子証明書から、発行者と有効期限だけを読みます。")
                    Label("暗証番号は使いません", systemImage: "lock.open")
                    Label("氏名・住所・生年月日は読みません", systemImage: "person.crop.circle.badge.xmark")
                }
                .font(.callout)

                if model.usesDemoCards {
                    demoSection
                } else if case .unavailable(let reason) = model.availability {
                    Section {
                        Text(ReaderModel.message(for: reason))
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("availability-message")
                    }
                }

                Section {
                    Button {
                        Task { await model.read() }
                    } label: {
                        HStack {
                            Text(model.phase == .reading ? "読み取り中…" : "カードを読む")
                            Spacer()
                            if model.phase == .reading { ProgressView() }
                        }
                    }
                    .disabled(!model.canRead)
                    .accessibilityIdentifier("read-button")
                }

                resultSection
            }
            .navigationTitle("IC 証明書リーダー")
        }
    }

    private var demoSection: some View {
        Section {
            ForEach(DemoCard.allCases, id: \.self) { card in
                Button {
                    model.demoCard = card
                } label: {
                    HStack {
                        Text(Self.title(of: card))
                        Spacer()
                        if model.demoCard == card { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityIdentifier("demo-card-\(card.rawValue)")
            }
        } header: {
            Text("デモ用の架空のカード")
        } footer: {
            Text("この端末では NFC が使えないため、架空のカードで動かしています。実際のカードは iPhone で読めます。")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch model.phase {
        case .idle, .reading:
            EmptyView()
        case .read(let summary):
            Section("読み取った証明書") {
                LabeledContent("状態") {
                    Text(Self.title(of: summary.validity()))
                        .foregroundStyle(summary.validity() == .valid ? .green : .red)
                        .accessibilityIdentifier("result-validity")
                }
                LabeledContent("有効期間") {
                    Text("\(summary.notBefore.formatted(Self.day)) 〜 \(summary.notAfter.formatted(Self.day))")
                        .accessibilityIdentifier("result-period")
                }
                LabeledContent("発行者") {
                    Text(summary.issuer).multilineTextAlignment(.trailing)
                }
            }
        case .failed(let error):
            Section {
                Text(ReaderModel.message(for: error))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("error-message")
            }
        }
    }

    private static let day = Date.FormatStyle(date: .long, time: .omitted, locale: Locale(identifier: "ja_JP"))

    static func title(of card: DemoCard) -> String {
        switch card {
        case .valid: "有効な証明書のカード"
        case .expired: "証明書の期限が切れたカード"
        case .otherCard: "マイナンバーカード以外のカード"
        case .connectionLost: "読み取り中に離れるカード"
        @unknown default: card.rawValue
        }
    }

    static func title(of validity: CertificateSummary.Validity) -> String {
        switch validity {
        case .valid: "有効"
        case .expired: "期限切れ"
        case .notYetValid: "まだ有効ではありません"
        @unknown default: "不明"
        }
    }
}
