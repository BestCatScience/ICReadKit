# ICReadKit

マイナンバーカードの IC チップを NFC で読む SDK の構成例です。**iOS（Swift、XCFramework）と Android（Java、AAR）の SDK**と、それぞれを組み込む**サンプルアプリ（SwiftUI と Kotlin・Jetpack Compose）**が入っています。両 OS の SDK は同じ設計、同じ版、同じ識別子で、**1 組の Maestro のシナリオで両 OS の画面を確かめます**。

## 何を読むか

公的個人認証（JPKI）の領域にある**利用者証明用電子証明書**だけを読み、**発行者と有効期間**だけをアプリに返します。

- 暗証番号は使いません。カードに送る命令は SELECT と READ BINARY の 2 種類だけで、暗証番号を照合する命令（VERIFY など）は組み立てられない作りです。暗証番号を間違えると回数が減ってカードがロックされるため、試すこともしません。
- 氏名・住所・生年月日・マイナンバーは読みません。利用者証明用電子証明書にはこれらが入っていません（入っているのは署名用電子証明書で、そちらは暗証番号が要ります）。
- 証明書のシリアル番号、主体者名、公開鍵、証明書のバイト列そのものも、SDK の外に出しません。

## 両 OS の対応

| | iOS | Android |
|---|---|---|
| SDK の言語 | Swift 6（厳密な並行性チェック、型付きの throws） | Java 17 |
| 配布 | XCFramework（ライブラリの互換を保つビルド）、Swift Package | AAR（組み込み先の難読化向けの keep ルールを同梱） |
| 最低対応 | iOS 16 | Android 8.0（API 26） |
| NFC | Core NFC（NFCTagReaderSession、ISO 7816） | 読み取りモード（NfcAdapter、IsoDep、NFC-B） |
| サンプルアプリ | SwiftUI、Observation | Kotlin、Jetpack Compose |
| 端末なしの動作 | シミュレーターで自動的にデモカード | NFC のない端末・エミュレーターで自動的にデモカード |
| 単体テスト | Swift Testing（34 件） | JUnit（21 件） |
| UI テスト | XCUITest（6 件） | Compose UI テスト（4 件） |
| E2E | Maestro（共有の 3 シナリオ） | Maestro（同じ 3 シナリオ） |
| 静的検査 | 公開 API の基準との比較 | Android Lint（最低対応 OS にない API を止める） |
| 設定 | XcodeGen（チェックサム固定） | Gradle ラッパー（9.0） |

## 構成

```
Sources/ICReadKit/            iOS の SDK（依存なし）
App/ICReadSample/             iOS のサンプルアプリ
App/ICReadSampleUITests/      XCUITest
Tests/ICReadKitTests/         Swift の単体テスト
android/icreadkit/            Android の SDK（依存なし）と JUnit のテスト
android/sample/               Android のサンプルアプリと Compose の UI テスト
maestro/ci/                   両 OS で共有する E2E のシナリオ
api/ICReadKit.json            iOS の公開 API の基準
docs/spec/integration.adoc    事業者向けの組み込み仕様書（AsciiDoc）
docs/design.md                設計の判断
scripts/                      生成・ビルド・検査・E2E のスクリプトとその検査
```

どちらの SDK も、読み取りの処理を「カードに命令を送る口」から切り離してあります。実機の NFC、テスト用の台本、デモカードのどれでも同じ処理が動くので、分割読み出し、カードの拒否、壊れた証明書、途中で離れたカードを、端末なしでテストできます。

## 組み込み方（iOS）

1. `ICReadKit.xcframework` を Embed & Sign で追加するか、Swift Package として追加します。
2. Info.plist に `NFCReaderUsageDescription` と、`com.apple.developer.nfc.readersession.iso7816.select-identifiers`（`D392F000260100000001`）を入れます。欠けていると `availability()` が理由付きで知らせます。
3. entitlements の `com.apple.developer.nfc.readersession.formats` には **`TAG` だけ**を入れます。最低対応 OS が iOS 13 以降のアプリに `NDEF` を入れると、App Store へのアップロードで弾かれると報告されています（ITMS-90778）。entitlements は組み込み先の設定なので、SDK からは直せません。
4. `availability()` を確かめてから `readCertificateSummary()` を呼びます。公開した列挙型は後でケースを足せるように固定していないので、`switch` には `@unknown default` が要ります。

```swift
let reader = CardReader(onEvent: { event in analytics.send(event) })
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
} catch { … }
```

## iPhone のマイナンバーカード（Apple Wallet）の経路（iOS 18 以降）

IC を NFC で読む経路のほかに、Apple Wallet に入れたマイナンバーカードで確認する経路（`WalletIDReader`）があります。

- 要求できるのは、氏名、住所、生年月日、性別、顔写真、年齢の下限だけです。**個人番号（マイナンバー）を要求する手段はありません。** 民間事業者が個人番号を集めてよいのは税・社会保障などの手続きに限られるためで、セキュリティの検査でも止めています。
- SDK は Wallet が返す暗号化されたデータ（ISO/IEC 18013-5 の応答）を開けずに、そのまま組み込み先に渡します。復号、発行者の署名、端末の署名、nonce の照合は組み込み先のサーバーで行います。nonce はサーバーが毎回作って渡します。
- 年齢だけが要るなら `.ageAtLeast(18)` を使い、生年月日は求めません。保存するなら `storeForDays` で日数を示し、Wallet の画面で利用者に伝わるようにします。
- 実際に使うには、Apple の in-app identity presentment の entitlement（アプリの Bundle ID ごとに申請）と、マイナンバーカードを使う本人確認サービスとしてのデジタル庁の機能認証が要ります。このリポジトリのサンプルには entitlement がないので、実機でも「使えない」と表示されます。要求の組み立てとエラーの変換は単体テストで確かめています。
- Android は、日本のマイナンバーカードが Android のウォレットにまだ載っていないため、この経路を入れていません。

```swift
if #available(iOS 18.0, *) {
    let wallet = WalletIDReader(merchantIdentifier: "merchant.example")
    guard await wallet.availability(for: [.name, .ageAtLeast(18)]) == .available else { return }
    let presentation = try await wallet.requestPresentation(of: [.name, .ageAtLeast(18)], nonce: nonceFromServer)
    try await api.verify(presentation.encryptedData)   // サーバーで復号して検証する
}
```

## 組み込み方（Android）

1. `icreadkit-<版>.aar` を追加します。難読化向けの keep ルールは AAR に入っているので、組み込み先で書き足す必要はありません。
2. `CardReader.availability(context)` が `AVAILABLE` のときだけ読み取りボタンを有効にします。`NFC_DISABLED` なら NFC の設定画面に案内します。
3. 読み取りを始めるときに `startSession()` を呼び、`NfcAdapter.enableReaderMode` に `CardReader.READER_MODE_FLAGS` を渡します。見つかったタグは、読み取りモードのコールバックのスレッドで `session.read(tag)` に渡します（カードの応答を待つ間ブロックするため、メインスレッドでは呼びません）。
4. 画面を離れたら `session.cancel()` を呼びます。離脱として計測されます。

```kotlin
val reader = CardReader { event -> runOnUiThread { analytics.send(event) } }
session = reader.startSession()
adapter.enableReaderMode(activity, { tag ->
    try { show(session.read(tag)) } catch (e: CardReadException) { show(e.reason) }
}, CardReader.READER_MODE_FLAGS, null)
```

## エラーと、組み込み先がすること

| iOS | Android | アプリがすること |
|---|---|---|
| `unavailable` | `NO_NFC_HARDWARE`、`NFC_DISABLED` | 理由を表示する。無効なら設定へ案内する |
| `cancelled` | `CANCELLED` | 何もしない（利用者の意思） |
| `timeout` | （読み取りモードは待ち続ける） | もう一度試せるようにする |
| `connectionLost` | `CONNECTION_LOST` | カードを動かさずに当て直すよう伝える |
| `unsupportedCard` | `UNSUPPORTED_CARD` | マイナンバーカードを当てるよう伝える |
| `cardRejected(statusWord:)` | `CARD_REJECTED`（`getStatusWord()`） | 状態語は問い合わせ用に記録し、利用者には一般的な文言で伝える |
| `malformedCertificate` | `MALFORMED_CERTIFICATE` | 読めなかったと伝える |
| `system(code:)` | ― | Core NFC のコードを記録する |

## 問い合わせを減らす診断ツール

組み込み先から来る問い合わせの多くは、SDK ではなくアプリ側の設定の問題です。`scripts/icreadkit_doctor.py` は、組み込み先の `.app`・`.ipa`・`.apk`・`.aar` を読んで、よくある設定ミスを ID・原因・直し方つきで出します。読むのは設定とバイナリのヘッダーだけで、利用者のデータには触れません。

```bash
python3 scripts/icreadkit_doctor.py ios path/to/App.app --entitlements path/to/App.entitlements
python3 scripts/icreadkit_doctor.py android path/to/app.apk
```

| ID | 見つけるもの |
|---|---|
| ICR-IOS-001〜003 | 利用目的の文言、読み取るアプリケーションの指定、最低対応 OS の不足 |
| ICR-IOS-004、005 | entitlements の TAG の不足、最低対応 OS が iOS 13 以降なのに NDEF がある（ITMS-90778） |
| ICR-IOS-006 | 同じ識別子のバンドルの重複（ITMS-90685） |
| ICR-AND-001 | 16 KB ページに揃っていない 64 ビットのネイティブライブラリ |
| ICR-AND-002〜005 | NFC の権限、minSdk、NFC の必須指定、AAR の keep ルール |

各 ID の説明と、カード側の問題（期限切れ、読めない機種、別のカード、NFC がオフ）への一次回答は [docs/support/troubleshooting.md](docs/support/troubleshooting.md) にあります。CI では、自分たちのサンプルアプリと AAR にも毎回この診断をかけています。

iOS の SDK には、Apple が SDK に求めるプライバシーマニフェスト（`PrivacyInfo.xcprivacy`）を同梱しています。トラッキングなし、収集するデータなし、理由の申告が要る API の使用なしと宣言しています。

## 計測イベント（離脱率）

両 OS とも、読み取りの各段階（開始、カード検出、終了と所要時間）をイベントで渡します。カードのデータは含まないので、そのまま監視基盤（Datadog など）に送れます。開始したのに読み取りまで行かなかった割合が離脱率で、カード検出の有無で「当てられなかった」と「途中で離れた」を分けられます。サンプルアプリはこの集計を画面に出します。

## 品質の仕組み

| 仕組み | 何を止めるか |
|---|---|
| 単体テスト（両 OS） | 命令のバイト列、分割読み出し、カードの拒否、証明書の解析、設定漏れ、計測イベント、デモカードの識別子の一致 |
| UI テスト（XCUITest、Compose） | デモカードの結果画面と離脱率の集計 |
| Maestro（`maestro/ci`、両 OS 共通） | 有効・期限切れ・別のカード。別のカードの後にもう一度読めることも確かめる |
| 公開 API の検査（`scripts/check-api.sh`） | iOS の組み込み先を壊す API の変更 |
| Android Lint | 最低対応 OS にない API の呼び出し（D8 が補えないもの） |
| リリース版の難読化ビルド | AAR に同梱した keep ルールが、組み込み先の難読化で効くこと |
| セキュリティの検査（`scripts/review_checks.py`） | 両 OS の SDK での URL の直書き、ログ出力、端末への保存、通信、暗証番号の命令、個人番号の要求、新しい依存。両 OS の版のずれ |
| Claude Code の hook（`.claude/settings.json`） | 上の検査に触れる編集をその場で拒否し、検査が通るまで作業を終えさせない |
| 毎週の定期実行と Dependabot | 新しい Xcode・エミュレーター・アクションで壊れたことに、コードを変えなくても気づく |

CI（`.github/workflows/ci.yml`）は、検査を Ubuntu で先に回し、通ったら iOS（macOS）と Android（Ubuntu）のジョブを並行して回します。E2E は macOS とエミュレーターの時間がかかるため、PR では画面に関わる変更のときだけ動き、main・手動・毎週の定期実行では必ず動きます。

タグ（例：`v0.2.0`）を push すると、両 OS の版がタグと一致することを確かめたうえで、XCFramework の zip、Swift Package Manager 用のチェックサム、README、Android の AAR が GitHub Release に出ます。

## 開発

```bash
# iOS
bash scripts/generate-project.sh        # チェックサム固定の XcodeGen で ICReadKit.xcodeproj を作る
xcodebuild test -project ICReadKit.xcodeproj -scheme ICReadKit -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project ICReadKit.xcodeproj -scheme ICReadSample -destination 'platform=iOS Simulator,name=iPhone 17'
bash scripts/build-xcframework.sh && bash scripts/check-api.sh

# Android（JDK 17 以降）
cd android && ./gradlew :icreadkit:testDebugUnitTest :icreadkit:lintRelease :sample:assembleRelease
cd android && ./gradlew :sample:connectedDebugAndroidTest   # エミュレーターが要る

# 両 OS 共通
python3 scripts/review_checks.py && python3 -m unittest discover -s scripts/tests
MAESTRO_DEVICE_ID=<シミュレーターの UDID> bash scripts/maestro.sh ios
MAESTRO_DEVICE_ID=emulator-5554 bash scripts/maestro.sh android
```

## やっていないこと

- 証明書の署名を、地方公共団体情報システム機構の認証局までたどって検証すること。この構成例は有効期間を見るだけです。
- 暗証番号が要る情報（署名用電子証明書、券面事項入力補助の基本 4 情報、マイナンバー）。
- 運転免許証や在留カードなど、ほかのカード。
- 実際のカードでの読み取りの確認（iPhone と Android の実機が要ります）。

カードの仕様は公開資料が少なく、AID とファイルの番号は公開されている技術記事（[マイナンバーカードを APDU で操作する](https://tex2e.github.io/blog/protocol/jpki-mynumbercard-with-apdu)）に基づきます。
