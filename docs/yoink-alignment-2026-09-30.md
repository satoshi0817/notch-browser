# Yoink の Mac 版仕様とノッチのファイル棚

調査日: 2026-09-30。対象は Mac 版 Yoink。iOS 版のロック・削除動作は混ぜない。

## 確認した仕様

- [公式製品ページ](https://eternalstorms.at/yoink/mac/)は、棚からのファイルドラッグは Finder と同様に移動・コピーを扱い、⌥でコピー、⌘で移動を強制できると説明している。
- [公式 Usage Tips](https://eternalstorms.at/yoink/mac/tips/)も同じ修飾キーを案内し、ファイルのロック、取り出し後の復元、Finder での表示を説明している。
- [Apple のドラッグ操作 API](https://developer.apple.com/documentation/appkit/nsdraggingsource/draggingsession%28_%3Asourceoperationmaskfor%3A%29)では、ドラッグ元が許可する操作を宣言し、ドロップ先とシステムが結果を決める。したがってブラウザへのアップロードで元ファイルを保持し、Finder の移動先では移動できるよう、棚は外部アプリにコピーと移動の両方を許可する。棚自体がドロップ後に `FileManager.moveItem` を実行しない。
- [Apple の横方向レイアウト](https://developer.apple.com/documentation/appkit/nscollectionviewflowlayout/scrolldirection)は、コレクションの幅を内容に応じて伸ばし、スクロールビューで横移動できる。

## NotchBrowser での対応

棚に取り込む時はファイル参照を保存し、元ファイルを動かさない。棚から外へドラッグする時は `.copy` と `.move` を許可し、⌥／⌘と受け手の選択に従う。ファイルをコピー・アップロードした場合、元ファイルは保持される。成功した取り出し後に棚の参照を外すかどうかは設定で選べ、ピン留めした参照は保持する。

表示は横一列の正方形タイルに変更した。幅を超える場合は横スクロールでき、ホバー時のツールチップにファイル名・元のパス・サイズを表示する。スタックは一つのタイルにまとめ、ダブルクリックか右クリックで展開できる。タイルサイズとホバー詳細を設定できる。

新規タブの見出しは検索語と URL の具体例を 4 秒ごとに切り替える。入力中は切り替えを止める。

## 残る差分

Yoink の非ファイルコンテンツ、クリップボード履歴、Share Extension、Handoff、アプリごとの除外、システム Services はこの更新の対象外。ドラッグ先の実際の操作はアプリごとに異なるため、特に Finder の別ボリューム、ブラウザ、Mail での確認を続ける。
