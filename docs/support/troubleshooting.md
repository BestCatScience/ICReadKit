# 問い合わせ対応の手引き

組み込み先からの問い合わせに、一次回答を返すための手引きです。設定や配布物の問題は、まず診断ツールで確かめてから答えます。

```bash
python3 scripts/icreadkit_doctor.py ios path/to/App.app --entitlements path/to/App.entitlements
python3 scripts/icreadkit_doctor.py android path/to/app.apk   # または kit.aar
```

診断ツールが出す ID は、この手引きの見出しと対応しています。回答には、ID、原因、直し方、確かめ方の 4 つを入れます。推測で答えず、根拠（診断の出力、エラーの種類、SDK の版、端末、OS）を添えます。

## まず集める情報

| 項目 | なぜ要るか |
|---|---|
| SDK の版（`CardReader.version` / `CardReader.VERSION`） | 版ごとに直った問題がある |
| 端末の機種と OS の版 | NFC の読み取りは機種差が大きい |
| 返ってきたエラーの種類と、`cardRejected` なら状態語 | 原因がほぼ決まる |
| 計測イベントの並び（開始、カード検出、終了） | 「当てられなかった」と「途中で離れた」を分けられる |
| 診断ツールの出力 | 設定の問題をその場で切り分けられる |

カードから読んだデータ、証明書、利用者の個人情報は受け取りません。

## iOS の設定

<a id="icr-ios-001"></a>
### ICR-IOS-001 利用目的の文言がない

- **原因:** Info.plist に `NFCReaderUsageDescription` がない、または空。
- **起きること:** `availability()` が `missingUsageDescription` を返し、読み取りボタンが出ない。
- **直し方:** 利用目的の文言を入れる。

<a id="icr-ios-002"></a>
### ICR-IOS-002 読み取るアプリケーションの指定がない

- **原因:** `com.apple.developer.nfc.readersession.iso7816.select-identifiers` に `D392F000260100000001` がない。
- **起きること:** `availability()` が `missingApplicationIdentifier` を返す。指定がないままだと、Core NFC はカードを見つけても渡してこない。
- **直し方:** 上の値を足す。

<a id="icr-ios-003"></a>
### ICR-IOS-003 最低対応 OS が低い

- **原因:** アプリの Deployment Target が iOS 16 より前。
- **直し方:** 16.0 以上にする。

<a id="icr-ios-004"></a>
### ICR-IOS-004 entitlements に TAG がない

- **原因:** `com.apple.developer.nfc.readersession.formats` に `TAG` がない。
- **直し方:** `TAG` を入れる。Xcode の Capabilities で「Near Field Communication Tag Reading」を有効にすると入る。

<a id="icr-ios-005"></a>
### ICR-IOS-005 NDEF が入っていて、アップロードで弾かれる（ITMS-90778）

- **原因:** 最低対応 OS が iOS 13 以降のアプリで、NFC の形式に `NDEF` が入っている。開発者フォーラムで、この組み合わせが App Store へのアップロードで ITMS-90778 になると報告されている（Apple の公式文書に条件の明記はない）。
- **起きること:** 手元のビルドは通り、TestFlight へ上げた段階で初めて失敗する。
- **直し方:** `NDEF` を外して `TAG` だけにする。ICReadKit は NDEF を使わない。
- **補足:** entitlements は組み込み先のアプリの設定で、SDK からは直せない。組み込み手順に明記している。

<a id="icr-ios-006"></a>
### ICR-IOS-006 同じ識別子のバンドルが複数ある（ITMS-90685）

- **原因:** 同じフレームワークが、本体と App Clip や拡張の両方に埋め込まれている。または SDK が抱えた依存を、組み込み先も別に入れている。
- **直し方:** フレームワークの埋め込み先を一つにする。ICReadKit は依存を持たないので、ICReadKit 自身が原因になるのは、本体と App Clip の両方に埋め込んだ場合だけ。

<a id="icr-ios-010"></a>
### ICR-IOS-010 entitlements を確かめられなかった

- **直し方:** 診断ツールに `--entitlements` でファイルを渡すか、署名済みの .app を渡す。

## Android の設定と配布物

<a id="icr-and-001"></a>
### ICR-AND-001 ネイティブライブラリが 16 KB ページに揃っていない

- **原因:** 64 ビットの `.so` の LOAD セグメントが 4 KB 境界でビルドされている。
- **起きること:** 16 KB ページの端末で読み込めない。Google Play の公式ページでは、2027 年 2 月 1 日以降、非対応のアプリは更新を出せない（以前の告知では 2025 年 11 月だった）。
- **直し方:** NDK r28 以降でビルドし直す。それ以前の NDK ではリンカーに `-Wl,-z,max-page-size=16384` を足す。外から持ってきた `.so` は対応版に替える。
- **補足:** ICReadKit の AAR はネイティブライブラリを含まない。

<a id="icr-and-002"></a>
### ICR-AND-002 NFC の権限がない

- **直し方:** `<uses-permission android:name="android.permission.NFC" />` を足す。ICReadKit の AAR を使えば、マニフェストの統合で自動で入る。

<a id="icr-and-003"></a>
### ICR-AND-003 minSdk が低い

- **直し方:** アプリの minSdk を 26 以上にする。

<a id="icr-and-004"></a>
### ICR-AND-004 NFC を必須にしている

- **起きること:** NFC のない端末では Play ストアにアプリが表示されない。
- **直し方:** `android:required="false"` にして、`CardReader.availability()` で NFC の有無を確かめる。

<a id="icr-and-005"></a>
### ICR-AND-005 AAR に keep ルールがない

- **起きること:** 組み込み先の R8 で、SDK の中のクラスが消されたり名前が変わったりして動かなくなる。
- **直し方:** `consumerProguardFiles` で keep ルールを同梱する。ICReadKit の AAR は同梱している。

## カードと読み取り

### 「期限切れのカードで落ちる」

ICReadKit は期限切れの証明書を、エラーではなく結果（`validity()` が `expired`）として返します。落ちる場合は ICReadKit の外が原因の可能性が高いので、クラッシュログの記号化（dSYM）と、落ちた場所の SDK の版を確かめます。SDK の中で落ちていれば不具合として扱い、再現用のテストを足してから直します。

### 「特定の機種で読めない」

1. エラーが `connectionLost` か、カード検出のイベントが何回出ているかを見る。2 回以上なら、カードが一度離れている。
2. その機種の NFC アンテナの位置（iPhone は上部、Android は機種ごとに違う）を案内する。
3. 同じ機種で別のカードを試してもらい、カード側か端末側かを切り分ける。
4. 再現した機種は対応端末リストに記録し、QA の端末で確かめる。

### 「別の種類のカードと言われる」

`unsupportedCard` は、カードに公的個人認証のアプリケーションがないことを意味します。運転免許証や交通系 IC カードを当てている場合がほとんどです。

### 「NFC がオフ」

Android では `availability()` が `NFC_DISABLED` を返します。`Settings.ACTION_NFC_SETTINGS` で設定画面に案内します。

### 「証明書が失効していないかも確かめたい」

端末の上では失効は分かりません。証明書のバイト列をサーバーに送り、公的個人認証のプラットフォーム事業者を通じて OCSP か CRL で確かめます。

## iPhone のマイナンバーカード（Apple Wallet）

### 「Wallet で確認のボタンが押せない」

`availability(for:)` が `cannotRequest` を返すのは、次のどれかです。

- Wallet にマイナンバーカードがない。
- iOS 18.5 より前。
- アプリに Apple の in-app identity presentment の entitlement がない。

### 「個人番号を取りたい」

ICReadKit は個人番号を要求できません。民間事業者が個人番号を集めてよいのは、税・社会保障などの手続きに限られるためです。
