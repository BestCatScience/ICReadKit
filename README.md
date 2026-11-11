# ICReadKit

マイナンバーカードの IC チップを NFC で読む、iOS 向け SDK の構成例です。SDK 本体（XCFramework として配る）と、それを組み込むサンプルアプリが入っています。

## 何を読むか

公的個人認証（JPKI）の領域にある**利用者証明用電子証明書**だけを読み、**発行者と有効期間**だけをアプリに返します。

- 暗証番号は使いません。カードに送る命令は SELECT と READ BINARY の 2 種類だけで、暗証番号を照合する命令（VERIFY など）は組み立てられない作りです。暗証番号を間違えると回数が減ってカードがロックされるため、試すこともしません。
- 氏名・住所・生年月日・マイナンバーは読みません。利用者証明用電子証明書にはこれらが入っていません（入っているのは署名用電子証明書で、そちらは暗証番号が要ります）。
- 証明書のシリアル番号、主体者名、公開鍵、証明書のバイト列そのものも、SDK の外に出しません。

## 構成

```
Sources/ICReadKit/         SDK 本体（依存なし、iOS 16 以降）
  CardReader.swift         公開の入口。availability() と readCertificateSummary()
  APDU.swift               命令の組み立て。SELECT と READ BINARY だけ
  JPKIReader.swift         証明書を分割して読む。カードの応答をエラーに変える
  DER.swift                証明書の解析に要る最小限の DER
  CertificateSummary.swift 発行者と有効期間。期限切れは結果であってエラーではない
  NFCCertificateSession.swift  Core NFC との接続。結果は必ず 1 回だけ返す
  DemoCard.swift           端末なしで画面を作るための架空のカード
App/ICReadSample/          組み込む側のサンプルアプリ（iOS 17 以降）
App/ICReadSampleUITests/   デモカードで全部の結果画面を確かめる UI テスト
Tests/ICReadKitTests/      単体テスト
api/ICReadKit.json         公開 API の基準
```

読み取りの処理は「カードに命令を送る口」を差し替えられる形にしてあり、実機の Core NFC、テスト用の台本、デモカードのどれでも同じ処理が動きます。

## 組み込み方

1. `ICReadKit.xcframework` を Embed & Sign で追加するか、Swift Package として追加します。
2. アプリの Info.plist に次の 2 つを入れます。どちらかが欠けていると `availability()` が理由付きで知らせます。
   - `NFCReaderUsageDescription`：利用目的の文言
   - `com.apple.developer.nfc.readersession.iso7816.select-identifiers`：`D392F000260100000001`
3. entitlements の `com.apple.developer.nfc.readersession.formats` には **`TAG` だけ**を入れます。最低対応 OS が iOS 13 以降のアプリに `NDEF` を入れると、App Store へのアップロードで弾かれると報告されています（ITMS-90778）。entitlements は組み込み先のアプリ側の設定なので、SDK からは直せません。
4. 読み取りボタンを出す前に `availability()` を確かめ、押されたら `readCertificateSummary()` を呼びます。

```swift
let reader = CardReader()
guard reader.availability() == .available else { return }
do {
    let summary = try await reader.readCertificateSummary()
    switch summary.validity() {
    case .valid: …
    case .expired: …       // エラーではなく結果。どう伝えるかはアプリが決める
    case .notYetValid: …
    @unknown default: …
    }
} catch .cancelled {
    // 利用者がシートを閉じた。失敗として扱わない
} catch {
    // CardReadError の各ケースに、アプリがすべきことを書いてある
}
```

`CardReadError` などの公開した列挙型は、後の版でケースを足せるように固定していません。組み込む側の `switch` には `@unknown default` が要ります。

| エラー | アプリがすること |
|---|---|
| `unavailable` | 理由を表示する。再試行しても直らない |
| `cancelled` | 何もしない（利用者の意思で閉じた） |
| `timeout` | もう一度試せるようにする |
| `connectionLost` | カードを動かさずに当て直すよう伝える |
| `unsupportedCard` | 別の種類のカード。マイナンバーカードを当てるよう伝える |
| `cardRejected(statusWord:)` | 状態語はサポート用の記録に残し、利用者には一般的な文言で伝える |
| `malformedCertificate` | 読めなかったと伝える |
| `system(code:)` | Core NFC の未対応のエラー。コードを記録する |

システムの読み取りシートに出る文言は `CardReader.Messages` で差し替えられます（既定は日本語）。

## 開発

```bash
bash scripts/generate-project.sh        # チェックサム固定の XcodeGen で ICReadKit.xcodeproj を作る
xcodebuild test -project ICReadKit.xcodeproj -scheme ICReadKit -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project ICReadKit.xcodeproj -scheme ICReadSample -destination 'platform=iOS Simulator,name=iPhone 17'
bash scripts/build-xcframework.sh       # build/ICReadKit.xcframework を作る
bash scripts/check-api.sh               # 公開 API が基準から壊れていないか確かめる
```

公開 API を意図して変えるときは `bash scripts/check-api.sh --update` で基準を更新し、何が壊れるかをコミットに書きます。

シミュレーターには NFC がないため、サンプルアプリは自動でデモカード（有効、期限切れ、別の種類のカード、読み取り中に離れる）に切り替わります。実際のカードは iOS 16 以降の iPhone（iPhone 8 以降）の実機で読めます。

## やっていないこと

- Android 版。
- 証明書の署名を、地方公共団体情報システム機構の認証局までたどって検証すること。この構成例は有効期間を見るだけです。
- 暗証番号が要る情報（署名用電子証明書、券面事項入力補助の基本 4 情報、マイナンバー）。
- 運転免許証や在留カードなど、ほかのカード。

カードの仕様は公開資料が少なく、AID とファイルの番号は公開されている技術記事（[マイナンバーカードを APDU で操作する](https://tex2e.github.io/blog/protocol/jpki-mynumbercard-with-apdu)）に基づきます。
