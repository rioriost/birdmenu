import Foundation

enum AppText {
    static var isJapanese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }

    static func localized(en: String, ja: String) -> String {
        isJapanese ? ja : en
    }

    static var status: String { localized(en: "Status", ja: "状態") }
    static var starting: String { localized(en: "Starting", ja: "起動中") }
    static var display: String { localized(en: "Display", ja: "表示") }
    static var allSensors: String { localized(en: "All Sensors", ja: "すべてのセンサー") }
    static var missingSensor: String { localized(en: "Missing Sensor", ja: "見つからないセンサー") }
    static var sensor: String { localized(en: "Sensor", ja: "センサー") }
    static var temperature: String { localized(en: "Temperature", ja: "温度") }
    static var humidity: String { localized(en: "Humidity", ja: "湿度") }
    static var battery: String { localized(en: "Battery", ja: "バッテリー") }
    static var signal: String { localized(en: "Signal", ja: "信号") }
    static var lastUpdate: String { localized(en: "Last update", ja: "最終更新") }
    static var history: String { localized(en: "History", ja: "履歴") }
    static var notFetched: String { localized(en: "Not fetched", ja: "未取得") }
    static var fetching: String { localized(en: "Fetching...", ja: "取得中...") }
    static var rawOnly: String { localized(en: "raw only", ja: "生データのみ") }
    static var failed: String { localized(en: "failed", ja: "失敗") }
    static var rescan: String { localized(en: "Rescan", ja: "再スキャン") }
    static var fetchSensorHistory: String { localized(en: "Fetch Sensor History (Experimental)", ja: "センサー履歴を取得（実験的）") }
    static var openHistoryFolder: String { localized(en: "Open History Folder", ja: "履歴フォルダを開く") }
    static var about: String { localized(en: "About BirdMenu...", ja: "BirdMenuについて...") }
    static var settings: String { localized(en: "Settings...", ja: "設定...") }
    static var quit: String { localized(en: "Quit BirdMenu", ja: "BirdMenuを終了") }
    static var ok: String { localized(en: "OK", ja: "OK") }

    static var scanning: String { localized(en: "Scanning for compatible sensors", ja: "対応センサーをスキャン中") }
    static var selectedSensorMissing: String { localized(en: "Selected sensor has not been seen", ja: "選択したセンサーはまだ検出されていません") }
    static var receivingBLE: String { localized(en: "Receiving BLE advertisements", ja: "BLE広告を受信中") }
    static var staleBLE: String { localized(en: "Last BLE advertisement is stale", ja: "最後のBLE広告が古くなっています") }
    static var noRecentBLE: String { localized(en: "No recent BLE advertisements", ja: "最近のBLE広告がありません") }

    static var noSensorSelectedTitle: String { localized(en: "No Sensor Selected", ja: "センサーが選択されていません") }
    static var noSensorSelectedMessage: String {
        localized(
            en: "Select a specific sensor, or wait until exactly one compatible sensor is detected.",
            ja: "特定のセンサーを選択するか、対応センサーが1台だけ検出されるまで待ってください。"
        )
    }
    static var historyFetchCompleteTitle: String { localized(en: "History Fetch Complete", ja: "履歴の取得が完了しました") }
    static var historyRawDumpSavedTitle: String { localized(en: "History Raw Dump Saved", ja: "履歴の生データを保存しました") }
    static var historyFetchFailedTitle: String { localized(en: "History Fetch Failed", ja: "履歴の取得に失敗しました") }
    static var couldNotOpenHistoryFolderTitle: String { localized(en: "Could Not Open History Folder", ja: "履歴フォルダを開けませんでした") }

    static var settingsTitle: String { localized(en: "BirdMenu Settings", ja: "BirdMenu設定") }
    static var launchAtLogin: String { localized(en: "Launch at login", ja: "ログイン時に起動") }
    static var temperatureUnit: String { localized(en: "Temperature unit", ja: "温度単位") }
    static var celsius: String { localized(en: "Celsius", ja: "摂氏") }
    static var fahrenheit: String { localized(en: "Fahrenheit", ja: "華氏") }
    static var debugLogging: String { localized(en: "Debug logging", ja: "デバッグログ") }

    static var bluetoothOff: String { localized(en: "Bluetooth is off", ja: "Bluetoothがオフです") }
    static var bluetoothUnauthorized: String { localized(en: "Bluetooth access is not allowed", ja: "Bluetoothの使用が許可されていません") }
    static var bluetoothUnsupported: String { localized(en: "This Mac does not support Bluetooth LE", ja: "このMacはBluetooth LEをサポートしていません") }
    static var bluetoothUnknown: String { localized(en: "Could not read Bluetooth state", ja: "Bluetooth状態を取得できません") }
}
