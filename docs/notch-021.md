# TASK-NOTCH-021

## DesignPreview

監督側でリポジトリのルートから実行する。ローカルのオフラインプレビューのみ。

```sh
./scripts/preview.sh --web-lifecycle=settings
./scripts/preview.sh --web-lifecycle=snapshot
./scripts/preview.sh --web-lifecycle=failed
./scripts/preview.sh --web-lifecycle=rest-demo
./scripts/preview.sh --tab-rest-seconds=20
```

順に「一般」の設定行、保存されたページのスナップショット、失敗表示を確認できる。
引数の解釈とフィクスチャは `#if DEBUG` 内のみ。Release には追加の引数・フィクスチャ文字列を含めない。

`--tab-rest-seconds=N` は DEBUG ビルドだけで休止までの秒数を上書きする（正の有限数のみ。未指定・不正値は通常設定に従う）。設定の保存値や本番メニューは変更しない。この引数を指定した場合だけ、期限の確認間隔を最大1秒に短縮する。ページを読み込んだタブから離れるかノッチを閉じ、約20秒後の休止・再表示時の復元を確認する。除外条件は通常どおり適用する。

失敗表示のプレビューは本番と共通の `WebTabFailureView` を使う。灰色テキストの下のボタンは、標準ベゼルを描画せず、systemBlue の塗りつぶしと白い文字を直接描く。明るい／暗い外観や非アクティブウインドウでも白いピルに変わらない。

失敗ビューの背景は webContainer と同じ `NSColor(white: 0.08, alpha: 1)`、文言は固定グレー `white: 0.68`。sRGB の線形化 `L(c) = ((c + 0.055) / 1.055)^2.4` から、背景の相対輝度は 0.007194、文字は 0.420033。コントラスト比は `(0.420033 + 0.05) / (0.007194 + 0.05) = 8.22:1` で、4.5:1 以上を確保する。青い再読み込みボタンの描画は変更しない。失敗表示時は読み込みを止め、WebKit が一時的に isLoading を返してもツールバーは回転しない `arrow.clockwise` を表示する。

`--web-lifecycle=rest-demo` は DEBUG 専用。ローカルのフィクスチャ HTML を読み込み、スクロール可能な高さを確保して240pxスクロールし、約0.4秒後に実際の `takeSnapshot` → 状態保存 → WebView 破棄を行う。本番と共通の休止処理・スナップショット表示を通り、合成画像は使わない。このデモの対象タブだけ、表示中の除外と通常の待ち時間を省略する。画像取得に失敗したら失敗表示にする。

画像はそのまま表示される。タブを選び直すか、ノッチを閉じて開くと、本番と共通の再開処理（ロード・スクロール復元・クロスフェード）を確認できる。デモ用の高さも再開時に同じフィクスチャへ適用する。デモ引数・フィクスチャ処理は Release に含めない。

DEBUG 専用の `./scripts/preview.sh --web-lifecycle=rest-demo --force-reduce-motion` で、システム設定を変更せず snapshot→live を即時切り替えにできる。画像切り替え開始時に category `web` の info ログへ `reduce-motion=instant`（通常は `duration=0.15`）とタブ UUID を出す。引数文字列・解釈・追加ログは Release に含めない。

## ログ確認

監督側で次のコマンドを先に開始し、その後別ターミナルからデモを起動する。`info` レベルを指定し、DesignPreview の bundle ID も対象にする。

```sh
/usr/bin/log stream --level info --style compact --predicate 'category == "web" AND (subsystem == "com.satoshi0817.NotchBrowser" OR subsystem == "com.satoshi0817.NotchBrowser.DesignPreview")'
./scripts/preview.sh --web-lifecycle=rest-demo
```

`tab=<UUID> action=rest phase=start success=true`、`phase=snapshot`、WebView 破棄後の `phase=finish` が出る。再表示すると `action=resume` の開始・完了が出る。WebContent 終了時は `action=terminate phase=event`、自動復旧は `action=auto-reload` の開始・完了または `phase=exhausted success=false` を出す。`phase=start` の成否は開始できたか、`phase=finish` は処理の成否を表す。すべて `os.Logger` の category `web`、レベル `info`。URL・本文・タイトル・エラー詳細は記録しない。

## 動作

- WebContent 終了をタブごとに保持し、表示中なら即座に、それ以外なら表示時に最大1回自動再読み込みする。成功しても自動試行枠は消費したまま。手動再読み込みで1回分を再武装する。
- 休止設定は全タブ共通。初期値30分。非表示になった時刻から計測し、15秒間隔で期限を確認する。
- 表示中の選択タブ、再生中のメディア、入力フォーカスを除外する。ネイティブ固定タブ3つは Web タブの休止対象配列に含まれない。Web の固定タブは含まれる。
- スナップショットはメモリだけに保存し、再開完了・タブ破棄・終了通知で解放する。ディスクへの保存はない。
- URL・タイトル・ズーム・スクロール位置を保持する。アイコンは従来のホスト名に基づく SF Symbols 表示を維持する（既存実装に実 favicon の取得はない）。
- 再開時は保存画像を先に表示し、ロードと既存 transfer JS によるスクロール復元の完了後、0.15秒でライブ表示へ移行する。macOS の「動きを減らす」が有効なら即時に切り替える。
- `os.Logger` の `web` カテゴリにはランダムなタブ UUID と復旧結果のみを記録し、URL・タイトル・本文・トークン・エラー本文は記録しない。外部送信処理は追加しない。

## 監督側での検証

`swift test` は作業側では実行しない。追加テストは `Notch021Tests`。既存テストは変更しない。
実 WebKit のプロセス終了、期限経過、メディア・入力除外、ロード失敗、スクロール復元、Reduce Motion は実機でも確認する。
