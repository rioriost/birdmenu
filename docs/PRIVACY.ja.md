# BirdMenu プライバシーポリシー

最終更新日: 2026年6月29日

BirdMenuは、対応するBluetooth Low Energy温湿度センサーの値を表示するmacOSメニューバーアプリです。

## 概要

BirdMenuは、個人情報を収集、送信、販売、共有、追跡しません。分析SDK、広告SDK、トラッキングSDK、第三者のデータサービスは使用していません。

Bluetoothで取得した測定値や履歴ファイルは、すべてユーザーのMac上で処理・保存されます。

## ローカルで処理するデータ

BirdMenuは、近くにある対応センサーから次のデータを処理する場合があります。

- 温度
- 湿度
- 電池残量
- Bluetooth信号強度（RSSI）
- Bluetoothデバイス名とローカルのperipheral識別子
- 測定値および履歴レコードのタイムスタンプ
- デバイス履歴のデバッグとデコードに必要なBluetoothの生パケット

これらのデータは、macOSメニューバーへの表示と、ユーザーが要求した場合のデバイス履歴の書き出しにのみ使用されます。

## ローカル保存

実験的な履歴取得機能を使用すると、BirdMenuは次の場所にファイルを書き出します。

```text
~/Documents/BirdMenu Logs/
```

書き出されるファイルには、次のものが含まれる場合があります。

- `raw-history.json`
- `history.csv`
- `history_yyyymmdd.png`

アプリのメニューでデバッグログを有効にした場合、BirdMenuは受信したBluetooth測定値やパケット情報をmacOS Unified Loggingに記録することがあります。これらのログはMac上に残り、macOSによって管理されます。

## データ共有

BirdMenuは、Bluetooth測定値、履歴書き出し、ログ、デバイス識別子、利用状況情報を、開発者または第三者へ送信しません。

## ネットワーク利用

BirdMenuのアプリ機能にはインターネット接続は必要ありません。

## Bluetooth権限

BirdMenuは、対応センサーを検出し通信するためにBluetoothアクセスを要求します。

## データ削除

書き出された履歴ファイルは、次の場所からいつでも削除できます。

```text
~/Documents/BirdMenu Logs/
```

macOSのシステムログは、macOSが提供するツールで削除できます。

## Apple診断情報

ユーザーがシステム設定でAppleへの解析情報やクラッシュレポートの共有を有効にしている場合、Appleの開発者ツールを通じて診断情報が提供されることがあります。BirdMenu自体はクラッシュレポートを独自に収集または送信しません。

## お問い合わせ

プライバシーに関する質問は、次のGitHub Issuesから連絡してください。

https://github.com/rioriost/birdmenu/issues

動作確認はINKBIRD ITH-11-Bハードウェアで行っています。BirdMenuはINKBIRDとは関係なく、承認や推奨を受けたものではありません。
