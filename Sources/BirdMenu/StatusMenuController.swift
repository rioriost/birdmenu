import AppKit
import Foundation

@MainActor
final class StatusMenuController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let scanner = InkbirdScanner()
    private let menu = NSMenu()
    private let statusItemText = NSMenuItem(title: "\(AppText.status): \(AppText.starting)", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "\(AppText.display): \(AppText.allSensors)", action: nil, keyEquivalent: "")
    private let deviceItem = NSMenuItem(title: "\(AppText.sensor): --", action: nil, keyEquivalent: "")
    private let temperatureItem = NSMenuItem(title: "\(AppText.temperature): --", action: nil, keyEquivalent: "")
    private let humidityItem = NSMenuItem(title: "\(AppText.humidity): --", action: nil, keyEquivalent: "")
    private let batteryItem = NSMenuItem(title: "\(AppText.battery): --", action: nil, keyEquivalent: "")
    private let signalItem = NSMenuItem(title: "\(AppText.signal): --", action: nil, keyEquivalent: "")
    private let lastUpdateItem = NSMenuItem(title: "\(AppText.lastUpdate): --", action: nil, keyEquivalent: "")
    private let historyItem = NSMenuItem(title: "\(AppText.history): --", action: nil, keyEquivalent: "")

    private var readingsByPeripheralID: [UUID: InkbirdReading] = [:]
    private var selectedPeripheralID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPeripheralID?.uuidString, forKey: Self.selectedPeripheralDefaultsKey)
        }
    }
    private var scannerStatus: BLEScannerStatus = .starting
    private var timer: Timer?
    private var isFetchingHistory = false
    private var historyStatus: HistoryDisplayStatus = .notFetched
    private var settingsWindowController: SettingsWindowController?

    private static let selectedPeripheralDefaultsKey = "selectedPeripheralID"

    init() {
        selectedPeripheralID = UserDefaults.standard.string(forKey: Self.selectedPeripheralDefaultsKey).flatMap(UUID.init(uuidString:))
        configureStatusItem()
        configureScanner()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localeDidChange),
            name: NSLocale.currentLocaleDidChangeNotification,
            object: nil
        )
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureStatusItem() {
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.menu = menu
    }

    private func configureScanner() {
        scanner.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.scannerStatus = status
                self?.refresh()
            }
        }
        scanner.onReading = { [weak self] reading in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.readingsByPeripheralID[reading.peripheralID] = reading
                if let selectedPeripheralID = self.selectedPeripheralID,
                   self.readingsByPeripheralID[selectedPeripheralID] == nil {
                    self.selectedPeripheralID = nil
                }
                self.refresh()
            }
        }
    }

    @objc private func selectAllDevices() {
        selectedPeripheralID = nil
        refresh()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let uuid = UUID(uuidString: uuidString) else {
            return
        }
        selectedPeripheralID = uuid
        refresh()
    }

    @objc private func rescan() {
        scanner.restart()
    }

    @objc private func fetchHistory() {
        guard let reading = historyTargetReading() else {
            showAlert(title: AppText.noSensorSelectedTitle, message: AppText.noSensorSelectedMessage)
            return
        }
        isFetchingHistory = true
        historyStatus = .fetching
        refresh()
        scanner.fetchHistory(for: reading) { [weak self] result in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.isFetchingHistory = false
                switch result {
                case let .success(history):
                    if let csvURL = history.csvURL {
                        self.historyStatus = .records(history.recordCount)
                        let pngLines = history.pngURLs.isEmpty
                            ? ""
                            : "\nPNG:\n\(history.pngURLs.map(\.path).joined(separator: "\n"))"
                        self.showAlert(
                            title: AppText.historyFetchCompleteTitle,
                            message: Self.historyCompleteMessage(history: history, csvURL: csvURL, pngLines: pngLines)
                        )
                    } else {
                        self.historyStatus = .rawOnly
                        self.showAlert(
                            title: AppText.historyRawDumpSavedTitle,
                            message: Self.historyRawDumpMessage(history: history)
                        )
                    }
                case let .failure(error):
                    self.historyStatus = .failed
                    self.showAlert(title: AppText.historyFetchFailedTitle, message: error.localizedDescription)
                }
                self.refresh()
            }
        }
    }

    @objc private func openLatestHistoryFolder() {
        let historyFolderURL = Self.historyRootFolderURL()
        do {
            try FileManager.default.createDirectory(at: historyFolderURL, withIntermediateDirectories: true)
        } catch {
            showAlert(title: AppText.couldNotOpenHistoryFolderTitle, message: error.localizedDescription)
            return
        }
        NSWorkspace.shared.open(historyFolderURL)
    }

    @objc private func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showSettings() {
        guard settingsWindowController == nil else {
            settingsWindowController?.show()
            return
        }
        let controller = SettingsWindowController()
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.settingsWindowController = nil
                self?.refresh()
            }
        }
        controller.onChange = { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        settingsWindowController = controller
        refresh()
        controller.show()
    }

    @objc private func localeDidChange() {
        settingsWindowController?.reload()
        refresh()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refresh() {
        let displayState = currentDisplayState()
        statusItem.button?.image = Self.statusImage(color: displayState.color)
        statusItem.button?.title = displayState.title
        statusItem.button?.toolTip = displayState.tooltip

        statusItemText.title = "\(AppText.status): \(displayState.statusText)"
        updateDetailItems()
        rebuildMenu()
    }

    private func updateDetailItems() {
        guard let snapshot = selectedSnapshot() else {
            displayItem.title = "\(AppText.display): \(selectedPeripheralID == nil ? AppText.allSensors : AppText.missingSensor)"
            deviceItem.title = "\(AppText.sensor): --"
            temperatureItem.title = "\(AppText.temperature): --"
            humidityItem.title = "\(AppText.humidity): --"
            batteryItem.title = "\(AppText.battery): --"
            signalItem.title = "\(AppText.signal): --"
            lastUpdateItem.title = "\(AppText.lastUpdate): --"
            historyItem.title = historyStatus.menuTitle
            return
        }

        displayItem.title = "\(AppText.display): \(snapshot.isAggregate ? AppText.allSensors : snapshot.label)"
        deviceItem.title = "\(AppText.sensor): \(snapshot.label)"
        temperatureItem.title = "\(AppText.temperature): \(Self.formatTemperature(snapshot.temperatureCelsius))"
        humidityItem.title = "\(AppText.humidity): \(Self.formatHumidity(snapshot.humidityPercent))"
        batteryItem.title = snapshot.batteryPercent.map { "\(AppText.battery): \($0)%" } ?? "\(AppText.battery): --"
        signalItem.title = snapshot.rssi.map { "\(AppText.signal): \($0) dBm" } ?? "\(AppText.signal): --"
        lastUpdateItem.title = "\(AppText.lastUpdate): \(Self.relativeTime(since: snapshot.date))"
        historyItem.title = historyStatus.menuTitle
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(statusItemText)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(deviceItem)
        menu.addItem(temperatureItem)
        menu.addItem(humidityItem)
        menu.addItem(batteryItem)
        menu.addItem(signalItem)
        menu.addItem(lastUpdateItem)
        menu.addItem(NSMenuItem.separator())

        let allDevicesItem = NSMenuItem(title: AppText.allSensors, action: #selector(selectAllDevices), keyEquivalent: "")
        allDevicesItem.target = self
        allDevicesItem.state = selectedPeripheralID == nil ? .on : .off
        menu.addItem(allDevicesItem)

        for reading in sortedReadings() {
            let item = NSMenuItem(title: deviceSelectionTitle(for: reading), action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = reading.peripheralID.uuidString
            item.state = selectedPeripheralID == reading.peripheralID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let rescanItem = NSMenuItem(title: AppText.rescan, action: #selector(rescan), keyEquivalent: "")
        rescanItem.target = self
        menu.addItem(rescanItem)

        menu.addItem(NSMenuItem.separator())
        let fetchHistoryItem = NSMenuItem(title: AppText.fetchSensorHistory, action: #selector(fetchHistory), keyEquivalent: "")
        fetchHistoryItem.target = self
        fetchHistoryItem.isEnabled = !isFetchingHistory && historyTargetReading() != nil
        menu.addItem(fetchHistoryItem)

        let openHistoryFolderItem = NSMenuItem(title: AppText.openHistoryFolder, action: #selector(openLatestHistoryFolder), keyEquivalent: "")
        openHistoryFolderItem.target = self
        menu.addItem(openHistoryFolderItem)

        menu.addItem(NSMenuItem.separator())
        let aboutItem = NSMenuItem(title: AppText.about, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: AppText.settings, action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.isEnabled = settingsWindowController == nil
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: AppText.quit, action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func currentDisplayState() -> (title: String, color: NSColor, statusText: String, tooltip: String) {
        if case let .bluetoothUnavailable(reason) = scannerStatus {
            let text = Self.bluetoothUnavailableText(for: reason)
            return ("--.-\(TemperatureUnit.current == .celsius ? "°C" : "°F") --%", .systemRed, text, "BirdMenu: \(text)")
        }

        guard let snapshot = selectedSnapshot() else {
            let status = selectedPeripheralID == nil ? AppText.scanning : AppText.selectedSensorMissing
            return ("--.-\(TemperatureUnit.current == .celsius ? "°C" : "°F") --%", .systemOrange, status, "BirdMenu: \(status)")
        }

        let age = Date().timeIntervalSince(snapshot.date)
        let text = "\(Self.formatTemperature(snapshot.temperatureCelsius)) \(Self.formatHumidity(snapshot.humidityPercent))"
        if age <= 120 {
            return (text, .systemGreen, AppText.receivingBLE, "BirdMenu: \(snapshot.label)")
        }
        if age <= 600 {
            return (text, .systemOrange, AppText.staleBLE, "BirdMenu: \(AppText.lastUpdate) \(Self.relativeTime(since: snapshot.date))")
        }
        return (text, .systemRed, AppText.noRecentBLE, "BirdMenu: \(AppText.lastUpdate) \(Self.relativeTime(since: snapshot.date))")
    }

    private func selectedSnapshot() -> DisplaySnapshot? {
        if let selectedPeripheralID {
            guard let reading = readingsByPeripheralID[selectedPeripheralID] else {
                return nil
            }
            return DisplaySnapshot(reading: reading, label: deviceLabel(for: reading))
        }

        let readings = sortedReadings()
        guard !readings.isEmpty else {
            return nil
        }
        if readings.count == 1, let reading = readings.first {
            return DisplaySnapshot(reading: reading, label: deviceLabel(for: reading))
        }

        let temperatures = readings.map(\.temperatureCelsius)
        let humidities = readings.compactMap(\.humidityPercent)
        let freshest = readings.max { $0.date < $1.date }!
        let averageTemperature = temperatures.reduce(0, +) / Double(temperatures.count)
        let averageHumidity = humidities.isEmpty ? nil : humidities.reduce(0, +) / Double(humidities.count)

        return DisplaySnapshot(
            label: "\(AppText.allSensors) (\(readings.count))",
            temperatureCelsius: averageTemperature,
            humidityPercent: averageHumidity,
            batteryPercent: nil,
            rssi: nil,
            date: freshest.date,
            isAggregate: true
        )
    }

    private func historyTargetReading() -> InkbirdReading? {
        if let selectedPeripheralID {
            return readingsByPeripheralID[selectedPeripheralID]
        }
        let readings = sortedReadings()
        return readings.count == 1 ? readings.first : nil
    }

    private func sortedReadings() -> [InkbirdReading] {
        readingsByPeripheralID.values.sorted {
            let left = deviceLabel(for: $0)
            let right = deviceLabel(for: $1)
            if left == right {
                return $0.peripheralID.uuidString < $1.peripheralID.uuidString
            }
            return left < right
        }
    }

    private func deviceSelectionTitle(for reading: InkbirdReading) -> String {
        deviceLabel(for: reading)
    }

    private func deviceLabel(for reading: InkbirdReading) -> String {
        "\(AppText.sensor) \(Self.shortID(reading.peripheralID))"
    }

    private static func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.replacingOccurrences(of: "-", with: "").suffix(4)).uppercased()
    }

    private static func historyRootFolderURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BirdMenu Logs", isDirectory: true)
    }

    private static func statusImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 11, height: 11)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 9, height: 9)).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 9, height: 9)).stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func formatTemperature(_ value: Double) -> String {
        TemperatureUnit.current.formatted(value)
    }

    private static func formatHumidity(_ value: Double?) -> String {
        guard let value else {
            return "--%"
        }
        return String(format: "%.0f%%", value)
    }

    private static func relativeTime(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return AppText.localized(en: "\(seconds)s ago", ja: "\(seconds)秒前")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return AppText.localized(en: "\(minutes)m ago", ja: "\(minutes)分前")
        }
        let hours = minutes / 60
        return AppText.localized(en: "\(hours)h ago", ja: "\(hours)時間前")
    }

    private static func bluetoothUnavailableText(for reason: BluetoothUnavailableReason) -> String {
        switch reason {
        case .poweredOff:
            AppText.bluetoothOff
        case .unauthorized:
            AppText.bluetoothUnauthorized
        case .unsupported:
            AppText.bluetoothUnsupported
        case .unknown:
            AppText.bluetoothUnknown
        }
    }

    private static func historyCompleteMessage(history: InkbirdHistoryResult, csvURL: URL, pngLines: String) -> String {
        if AppText.isJapanese {
            return "\(history.recordCount)件の履歴レコードと\(history.packetCount)件の生パケットを保存しました。\n\nCSV: \(csvURL.path)\(pngLines)\nRaw: \(history.rawURL.path)"
        }
        return "Saved \(history.recordCount) decoded records and \(history.packetCount) raw packets.\n\nCSV: \(csvURL.path)\(pngLines)\nRaw: \(history.rawURL.path)"
    }

    private static func historyRawDumpMessage(history: InkbirdHistoryResult) -> String {
        if AppText.isJapanese {
            return "\(history.packetCount)件の生パケットを保存しましたが、CSVとして確実にデコードできませんでした。\n\nRaw: \(history.rawURL.path)"
        }
        return "Saved \(history.packetCount) raw packets, but could not confidently decode them into CSV yet.\n\nRaw: \(history.rawURL.path)"
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppText.ok)
        alert.runModal()
    }
}

private enum HistoryDisplayStatus {
    case notFetched
    case fetching
    case records(Int)
    case rawOnly
    case failed

    var menuTitle: String {
        switch self {
        case .notFetched:
            "\(AppText.history): \(AppText.notFetched)"
        case .fetching:
            "\(AppText.history): \(AppText.fetching)"
        case let .records(count):
            AppText.isJapanese ? "\(AppText.history): \(count)件" : "\(AppText.history): \(count) records"
        case .rawOnly:
            "\(AppText.history): \(AppText.rawOnly)"
        case .failed:
            "\(AppText.history): \(AppText.failed)"
        }
    }
}

private struct DisplaySnapshot {
    let label: String
    let temperatureCelsius: Double
    let humidityPercent: Double?
    let batteryPercent: Int?
    let rssi: Int?
    let date: Date
    let isAggregate: Bool

    init(reading: InkbirdReading, label: String) {
        self.label = label
        temperatureCelsius = reading.temperatureCelsius
        humidityPercent = reading.humidityPercent
        batteryPercent = reading.batteryPercent
        rssi = reading.rssi
        date = reading.date
        isAggregate = false
    }

    init(
        label: String,
        temperatureCelsius: Double,
        humidityPercent: Double?,
        batteryPercent: Int?,
        rssi: Int?,
        date: Date,
        isAggregate: Bool
    ) {
        self.label = label
        self.temperatureCelsius = temperatureCelsius
        self.humidityPercent = humidityPercent
        self.batteryPercent = batteryPercent
        self.rssi = rssi
        self.date = date
        self.isAggregate = isAggregate
    }
}
