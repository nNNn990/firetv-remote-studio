# Fire TV Remote Studio

Turn an Amazon Fire TV remote (Bluetooth LE, "Amazon Remote") into a programmable input device for your Mac,
and expose its built-in microphone as a push-to-talk macOS input device.

Amazon Fire TV リモコン（Bluetooth, "Amazon Remote"）を Mac のカスタマイズ入力デバイスにする macOS アプリです。
ボタンにショートカット・キー送信・アプリ起動・URL・メディア操作・レイヤー切替・マクロを割り当てられ、
リモコンの内蔵マイクを Push-to-Talk の仮想マイク「Fire TV Remote Microphone」として macOS に公開します。

![Fire TV Remote Studio](docs/screenshot.jpg)

> 非公式ツールです。Amazon とは無関係です。Fire TV リモコン第 2 世代（VID `0x0171` / PID `0x0413`）と第 3 世代（VID `0x0171` / PID `0x042F`）に対応しています。
> 第 2 世代にはアプリボタン（A1〜A4）がありません。他の世代は HID コードが異なる可能性がありますが、アプリ内の「ボタン学習」で未知のコードを登録できます。

## 機能

- **全ボタンのリマップ**: アプリボタン A1〜A4（第 3 世代のみ）、ホーム、メニュー、マイク、テレビマークに加え、排他モードでは音量・再生・方向キー・決定・戻る・電源も割り当て可
- **アクション**: macOS ショートカット（`shortcuts` CLI の一覧から選択）／キー送信（押している間ホールド、fn 修飾・修飾キーのみのホールド対応）／メディアキー／アプリ起動／URL／マクロ
- **レイヤー**: MO（押している間）、TG（トグル、排他）、TO（切替）、DF（デフォルト変更）。未設定ボタンは下位レイヤーを継承、ボタンごとに「デフォルト動作／無効／透過／カスタム」
- **仮想マイク**: リモコンのマイクボタンを押している間だけ声が「Fire TV Remote Microphone」に入る（Discord / QuickTime 等で確認）
- **メニューバー常駐**、ログイン時自動起動、設定のインポート／エクスポート、ライト／ダーク対応
- **表示言語**: English / 日本語（設定 → 一般 → 言語。macOS の仕様で再起動後に反映）
- Karabiner のような全キー監視や CGEventTap は使いません。触るのはこのリモコン 1 台だけです

## 動作環境

- macOS 14 Sonoma 以降（Apple Silicon / Intel）
- Fire TV リモコンを Mac と Bluetooth ペアリング済みであること
- 排他モード（音量・方向キー等のリマップ）と仮想マイクには管理者パスワードが必要（LaunchDaemon の承認、HAL ドライバのインストール）

## インストール

### リリースの .pkg から

`FireTVRemoteStudio.pkg` を開くと `/Applications/Fire TV Remote Studio.app` と
`/Library/Audio/Plug-Ins/HAL/FireTVRemoteMicrophone.driver` がインストールされます。再起動は不要です。

公証（notarization）していない pkg は Gatekeeper に止められます。その場合は
システム設定 → プライバシーとセキュリティ → 「このまま開く」で続行してください。

### ソースからビルド

```bash
xcode-select --install          # Swift 5.9 以降の Command Line Tools
brew install opus pkg-config
./build-app.sh                  # → FireTVRemoteBridge.app
open FireTVRemoteBridge.app
```

```bash
swift build && .build/debug/FireTVTests   # テスト（156 件）
./build-pkg.sh                             # → dist/FireTVRemoteStudio.pkg
```

Xcode プロジェクトは不要です。`build-app.sh` は "Developer ID Application" → "Apple Development" → ad-hoc の順に署名 ID を探します
（`CODESIGN_IDENTITY` で指定可）。ad-hoc 署名だと再ビルドのたびに「入力監視」の許可が消えるので、開発時でも Apple Development で署名することを勧めます。

配布用ビルドでは `scripts/build-libopus.sh` を先に実行してください。Homebrew の libopus は実行中の macOS 向けにリンクされているため、
このスクリプトが macOS 14 以降対応の universal な `libopus.0.dylib` を `vendor/libopus/` にビルドし、`build-app.sh` がそれを同梱します。

## 初回セットアップ

| 必要なもの | 用途 | 場所 |
|---|---|---|
| 入力監視 | リモコンの HID レポートを読む（必須） | システム設定 → プライバシーとセキュリティ → 入力監視 |
| アクセシビリティ | キー送信アクション | 同 → アクセシビリティ |
| helper の承認 | 排他モード（root でデバイスを seize） | 設定(⌘,) → 排他モード → 登録 → システム設定「ログイン項目と機能拡張」で許可 |
| HAL ドライバ | 仮想マイク | 設定(⌘,) → マイク → インストール（管理者認証） |

アプリの設定画面に現在の状態と各ボタンがあります。

入力監視を許可・変更したあとは、macOS の仕様でアプリの再起動が必要です。設定画面の「再確認」は現在のプロセスの状態を表示するだけなので、
許可後にアプリを終了して開き直してください。ad-hoc 署名のビルドは再ビルドごとに許可が無効になるため、入力監視の一覧から − で削除して再度追加するか、
Apple Development 署名を使ってください（`build-app.sh` は `NSInputMonitoringUsageDescription` を自動で付与します。
このキーが無いと `IOHIDCheckAccess` は許可済みでも常に denied を返します）。

**Karabiner-Elements を使っている場合**: Karabiner はキーボード類を排他取得するため、このリモコンを掴んでいるとアプリは
「別のプロセスがリモコンを専有しています」と表示します。Karabiner-Elements → Devices で "Amazon Remote" の Modify events をオフにしてください
（`karabiner.json` では `{"identifiers": {"vendor_id": 369, "product_id": 1071, "is_keyboard": true}, "ignore": true}`）。

## 使い方

1 ウィンドウ構成です。

- **上部バー**: デバイス名と接続状態（クリックでデバイス詳細・ボタン学習・ログ）／「マイク」ピル（待機／入力中レベル）／「有効」= 今効いているレイヤー／編集するレイヤー（⋯でレイヤー管理）／実機追従／マクロ／インポート・エクスポート／設定(⌘,)
- **中央**: リモコン。クリックまたは実機のボタンで選択。オレンジの点 = 割り当て済み、灰色の点 = 下位レイヤーから継承、🔒 = 排他モードが必要、`?` = 未学習
- **右のインスペクタ**: アクション種類と設定、テスト実行(⌘T)、割り当て解除、ほかのレイヤーでの割り当て

ショートカットは「ショートカットを選択…」のポップオーバーで検索・選択した時点で保存されます。
設定ファイルは `~/Library/Application Support/FireTVRemoteBridge/config.json`（壊れていれば `config.corrupt-*.json` に退避して初期化）。

### レイヤー

| 操作 | 意味 |
|---|---|
| MO(n) | 押している間だけレイヤー n を有効化（重ねられる） |
| TG(n) | レイヤー n に切替。もう一度押すか TG(デフォルト) でベースに戻る |
| TO(n) | レイヤー n だけを有効化（固定） |
| DF(n) | デフォルトレイヤーを n に変更（永続） |

ボタンごとのモード（全レイヤー）:

| モード | 意味 |
|---|---|
| デフォルト動作 | 元の macOS の機能をアプリが再送信（音量・再生等はメディアキー、方向キー・決定はキーイベント。長押しリピート付き）。未設定ボタンはこれ |
| 無効 | 何もしない |
| 透過 | 下位レイヤーの設定を継承（Layer 1 以上） |
| カスタム | ショートカット／キー送信／メディア／アプリ起動／URL／レイヤー操作／マクロ |

## 仕組み

```
HID 入力 (IOHIDManager, VID 0x0171 / PID 0x0413, 0x042F)
  → 通常モード: アプリが非排他で開く（macOS が処理するボタンは割り当て不可）
  → 排他モード: root helper (SMAppService LaunchDaemon) が kIOHIDOptionsTypeSeizeDevice で seize し、XPC で転送
  → レポート解析 → ButtonStateTracker（同時押し対応）
  → LayerEngine（有効レイヤー = デフォルト ∪ TG ∪ MO、上位から透過を飛ばして解決。押下時のアクションを解放まで保持）
  → ActionExecutor（shortcuts run / CGEvent / NSWorkspace / メディアキー / マクロ）または PassthroughEmitter（デフォルト動作の再送信）
```

- 一般ユーザー権限では seize が `kIOReturnNotPrivileged` で拒否されるため、排他モードだけ root helper を使います。helper はこの VID/PID のデバイスしか開きません。
- XPC には code-signing requirement を付けており、helper と同じ Developer Team で署名されたプロセスだけが接続できます（ad-hoc ビルドではバンドル ID のみの緩い検証になります）。
- アプリ終了・XPC 切断で helper はデバイスを解放し、macOS が再び処理します。helper が落ちた場合は通常モードへ自動フォールバックします。

### 仮想マイク

```
リモコン ──BLE HID──▶ helper / HIDMonitor ──▶ MicAudioEngine
   0xF2=01/00 (開始/停止) ◀──                  ├ libopus 復号 (16 kHz mono, 20 ms CELT) + PLC
   0xF0 80 B Opus ──▶                          ├ 3× ポリフェーズ FIR で 48 kHz Float32 へ
                                               └ /Users/Shared/FireTVRemoteStudio/mic.ring (mmap, lock-free)
   coreaudiod ◀── /Library/Audio/Plug-Ins/HAL/FireTVRemoteMicrophone.driver（AudioServerPlugIn, 48 kHz / 1ch / Float32）
```

- HAL プラグイン（`hal/FireTVMic.c`）は共有リングを読むだけで Bluetooth に触れません。アプリが動いていない間は無音を供給し、デバイス UID は固定です。
- IO スレッドでは mmap の memcpy のみ（XPC・ファイル I/O・ロックなし）。
- 実装上の注意: HID 受信バッファは 256 バイト必要（0xF0 は 81 バイト。64 だと欠けて金属的な音になる）。BLE HID の `IOHIDDeviceSetReport` はバッファ先頭に Report ID を含める必要がある。
- 調査の経緯と生データは [`mic-probe/README.md`](mic-probe/README.md)。

## 対応ボタン

| ボタン | HID | 通常モード | 排他モード |
|---|---|---|---|
| A1〜A4 | `ef/a1..a4` | ○ | ○ |
| テレビマーク | `02/008d` | ○ | ○ |
| マイク | `02/0221` | ○ | ○ |
| ホーム / メニュー | `02/0223` / `02/0040` | ○ | ○ |
| 音量+ / 音量− / ミュート | `02/00e9` / `02/00ea` / `02/00e2` | 🔒 | ○ |
| 再生 / 早送り / 巻き戻し | `02/00cd` / `02/00b3` / `02/00b4` | 🔒 | ○ |
| 上下左右 / 決定 / 戻る / 電源 | `01/52 51 50 4f` / `01/58` / `01/f1` / `01/66` | 🔒 | ○ |

## リポジトリ構成

| パス | 内容 |
|---|---|
| `Sources/FireTVCore/` | HID 解析・レイヤーエンジン・アクション実行・設定・helper クライアント・マイクエンジン |
| `Sources/FireTVHelper/` | root helper（seize + XPC 転送） |
| `Sources/FireTVIPC/` | アプリと helper の XPC プロトコル |
| `Sources/FireTVRemoteApp/` | SwiftUI GUI（`Theme.swift` がデザイントークン） |
| `Sources/CMicRing/`, `Sources/COpus/` | 共有リングバッファ、libopus モジュールマップ |
| `Sources/FireTVTests/` | テスト（XCTest 不要の実行ファイル） |
| `hal/` | HAL プラグインとビルドスクリプト |
| `scripts/` | ドライバのインストール／アンインストール、libopus のビルド |
| `shortcuts/` | 初期セットアップ用のサンプルショートカット（FireTV-A1〜A4） |
| `build-app.sh`, `build-pkg.sh` | `.app` / `.pkg` の生成 |
| `mic-probe/` | マイク取得の検証ツールと調査メモ |

## アンインストール

設定(⌘,) → マイク → アンインストール、または:

```bash
sudo "/Applications/Fire TV Remote Studio.app/Contents/Resources/uninstall.sh" --purge
```

ドライバ・共有バッファ・helper 登録・アプリ本体を削除します（`--purge` なしならアプリは残ります）。設定ファイルは残ります。

## 公開配布する場合（署名・公証）

1. `scripts/build-libopus.sh` で redistributable な libopus をビルド
2. "Developer ID Application" でアプリ・helper・HAL プラグインを署名（`build-app.sh` が自動で使用。`--options runtime --timestamp` 付き）
3. `build-pkg.sh` が "Developer ID Installer" で pkg を署名
4. `xcrun notarytool submit dist/FireTVRemoteStudio.pkg --keychain-profile <profile> --wait && xcrun stapler staple dist/FireTVRemoteStudio.pkg`
5. 検証: `spctl -a -vv -t install dist/FireTVRemoteStudio.pkg`

## ライセンス

MIT License。同梱する libopus は BSD ライセンスです（[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）。
