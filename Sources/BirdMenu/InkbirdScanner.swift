@preconcurrency import CoreBluetooth
import Foundation

enum BLEScannerStatus: Equatable {
    case starting
    case scanning
    case bluetoothUnavailable(BluetoothUnavailableReason)
}

enum BluetoothUnavailableReason: Equatable {
    case poweredOff
    case unauthorized
    case unsupported
    case unknown
}

final class InkbirdScanner: NSObject, CBCentralManagerDelegate {
    var onStatusChange: ((BLEScannerStatus) -> Void)?
    var onReading: ((InkbirdReading) -> Void)?

    private var centralManager: CBCentralManager!
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var historyOperation: HistoryFetchOperation?
    private var stateCheckTimer: Timer?

    override init() {
        super.init()
        BirdMenuLog.info("app.start debugLogging=\(BirdMenuLog.isDebugLoggingEnabled)")
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        scheduleStateCheck()
    }

    func restart() {
        guard centralManager.state == .poweredOn else {
            centralManagerDidUpdateState(centralManager)
            return
        }
        BirdMenuLog.debugData("scanner.restart")
        centralManager.stopScan()
        startScan()
    }

    func fetchHistory(
        for reading: InkbirdReading,
        completion: @escaping (Result<InkbirdHistoryResult, Error>) -> Void
    ) {
        guard centralManager.state == .poweredOn else {
            BirdMenuLog.debugData("history.fetch rejected bluetoothUnavailable")
            completion(.failure(HistoryFetchError.bluetoothUnavailable))
            return
        }
        guard historyOperation == nil else {
            BirdMenuLog.debugData("history.fetch rejected busy")
            completion(.failure(HistoryFetchError.busy))
            return
        }
        guard let peripheral = peripheralsByID[reading.peripheralID] else {
            BirdMenuLog.debugData("history.fetch rejected peripheralNotFound id=\(reading.peripheralID.uuidString)")
            completion(.failure(HistoryFetchError.peripheralNotFound))
            return
        }

        BirdMenuLog.debugData("history.fetch start device=\(reading.deviceName) id=\(reading.peripheralID.uuidString)")
        centralManager.stopScan()
        let operation = HistoryFetchOperation(
            centralManager: centralManager,
            peripheral: peripheral,
            peripheralDelegate: self,
            latestReading: reading,
            completion: { [weak self] result in
                self?.historyOperation = nil
                self?.centralManager.cancelPeripheralConnection(peripheral)
                self?.startScan()
                switch result {
                case let .success(history):
                    BirdMenuLog.debugData("history.fetch complete packets=\(history.packetCount) records=\(history.recordCount) raw=\(history.rawURL.path) csv=\(history.csvURL?.path ?? "-") warnings=\(history.warnings.joined(separator: " | "))")
                case let .failure(error):
                    BirdMenuLog.debugData("history.fetch failed error=\(error.localizedDescription)")
                }
                completion(result)
            }
        )
        historyOperation = operation
        operation.start()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            BirdMenuLog.debugData("scanner.state poweredOn")
            startScan()
        case .poweredOff:
            BirdMenuLog.debugData("scanner.state poweredOff")
            onStatusChange?(.bluetoothUnavailable(.poweredOff))
        case .unauthorized:
            BirdMenuLog.debugData("scanner.state unauthorized")
            onStatusChange?(.bluetoothUnavailable(.unauthorized))
        case .unsupported:
            BirdMenuLog.debugData("scanner.state unsupported")
            onStatusChange?(.bluetoothUnavailable(.unsupported))
        case .resetting:
            BirdMenuLog.debugData("scanner.state resetting")
            onStatusChange?(.starting)
        case .unknown:
            BirdMenuLog.debugData("scanner.state unknown")
            onStatusChange?(.starting)
        @unknown default:
            BirdMenuLog.debugData("scanner.state unknownDefault")
            onStatusChange?(.bluetoothUnavailable(.unknown))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            BirdMenuLog.debugData("advertisement.ignored reason=noManufacturerData name=\((advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "-") id=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue) keys=\(advertisementData.keys.sorted())")
            return
        }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard let reading = InkbirdAdvertisementParser.parse(
            advertisedName: advertisedName,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturerData,
            rssi: RSSI.intValue,
            peripheralID: peripheral.identifier
        ) else {
            BirdMenuLog.debugData(
                "advertisement.ignored reason=parseRejected name=\(advertisedName ?? "-") id=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue) services=\(serviceUUIDs.map { $0.uuidString }.joined(separator: ",")) mfrLen=\(manufacturerData.count) mfr=\(manufacturerData.hexString)"
            )
            return
        }
        peripheralsByID[peripheral.identifier] = peripheral
        BirdMenuLog.debugData(
            "reading device=\(reading.deviceName) id=\(reading.peripheralID.uuidString) tempC=\(String(format: "%.2f", reading.temperatureCelsius)) humidity=\(reading.humidityPercent.map { String(format: "%.2f", $0) } ?? "-") battery=\(reading.batteryPercent) rssi=\(reading.rssi) adv=\(reading.advertisementHex)"
        )
        onReading?(reading)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        BirdMenuLog.debugData("central.didConnect id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "-")")
        historyOperation?.didConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        BirdMenuLog.debugData("central.didFailToConnect id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.fail(error ?? HistoryFetchError.connectionFailed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        BirdMenuLog.debugData("central.didDisconnect id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.didDisconnect(peripheral, error: error)
    }

    private func startScan() {
        BirdMenuLog.debugData("scanner.startScan service=\(InkbirdAdvertisementParser.serviceUUIDString)")
        stateCheckTimer?.invalidate()
        stateCheckTimer = nil
        onStatusChange?(.scanning)
        centralManager.scanForPeripherals(
            withServices: [InkbirdAdvertisementParser.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func scheduleStateCheck() {
        stateCheckTimer?.invalidate()
        stateCheckTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(stateCheckTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func stateCheckTimerFired() {
        checkCentralManagerState()
    }

    private func checkCentralManagerState() {
        guard let centralManager else {
            return
        }
        BirdMenuLog.debugData("scanner.stateCheck state=\(centralManager.state.rawValue)")
        switch centralManager.state {
        case .poweredOn:
            startScan()
        case .unknown, .resetting:
            scheduleStateCheck()
        default:
            centralManagerDidUpdateState(centralManager)
        }
    }
}

extension InkbirdScanner: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        BirdMenuLog.debugData("peripheral.didDiscoverServices id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didDiscoverServices: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        BirdMenuLog.debugData("peripheral.didDiscoverCharacteristics service=\(service.uuid.uuidString) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        BirdMenuLog.debugData("peripheral.didUpdateNotificationState char=\(characteristic.uuid.uuidString) notifying=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        BirdMenuLog.debugData("peripheral.didUpdateValue char=\(characteristic.uuid.uuidString) bytes=\(characteristic.value?.count ?? 0) hex=\(characteristic.value?.hexString ?? "-") error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        BirdMenuLog.debugData("peripheral.didWriteValue char=\(characteristic.uuid.uuidString) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didWriteValueFor: characteristic, error: error)
    }
}

enum HistoryFetchError: LocalizedError {
    case bluetoothUnavailable
    case busy
    case peripheralNotFound
    case connectionFailed
    case serviceNotFound
    case historyCharacteristicNotFound
    case disconnected
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            "Bluetooth is not available."
        case .busy:
            "Another history fetch is already running."
        case .peripheralNotFound:
            "The selected sensor is not available. Wait for a fresh advertisement and try again."
        case .connectionFailed:
            "Could not connect to the selected sensor."
        case .serviceNotFound:
            "The expected Bluetooth service was not found."
        case .historyCharacteristicNotFound:
            "The history characteristic fff8 was not found."
        case .disconnected:
            "The device disconnected during history fetch."
        case let .timedOut(command):
            "Timed out while fetching \(command)."
        }
    }
}

private final class HistoryFetchOperation: @unchecked Sendable {
    private struct Command {
        let name: String
        let value: Data
        let quietTimeout: TimeInterval
        let maxTimeout: TimeInterval
        let readAfterWrite: Bool
    }

    private struct CommandAttempt {
        let command: Command
        let characteristic: CBCharacteristic
    }

    private enum TransferMode {
        case legacyFFF8(CBCharacteristic)
        case ith11BTrace(config: CBCharacteristic, clock: CBCharacteristic)
        case readOnlySnapshot
    }

    private static let inkbirdServiceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private static let configCharacteristicUUID = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    private static let ith11BConfigCharacteristicUUID = CBUUID(string: "0000FFF5-0000-1000-8000-00805F9B34FB")
    private static let ith11BCommandCharacteristicUUID = CBUUID(string: "0000FFF4-0000-1000-8000-00805F9B34FB")
    private static let notifyCharacteristicUUID = CBUUID(string: "0000FFF6-0000-1000-8000-00805F9B34FB")
    private static let ith11BClockCharacteristicUUID = CBUUID(string: "0000FFF7-0000-1000-8000-00805F9B34FB")
    private static let historyCharacteristicUUID = CBUUID(string: "0000FFF8-0000-1000-8000-00805F9B34FB")

    private let centralManager: CBCentralManager
    private let peripheral: CBPeripheral
    private weak var peripheralDelegate: CBPeripheralDelegate?
    private let latestReading: InkbirdReading
    private let completion: (Result<InkbirdHistoryResult, Error>) -> Void
    private let historyCommands: [Command] = [
        Command(name: "temp_header", value: Data([0x02]), quietTimeout: 0.8, maxTimeout: 5, readAfterWrite: true),
        Command(name: "temp_content", value: Data([0x01]), quietTimeout: 5, maxTimeout: 180, readAfterWrite: true),
        Command(name: "temp_content_crc", value: Data([0x07]), quietTimeout: 0.8, maxTimeout: 5, readAfterWrite: true),
        Command(name: "hum_header", value: Data([0x04]), quietTimeout: 0.8, maxTimeout: 5, readAfterWrite: true),
        Command(name: "hum_content", value: Data([0x03]), quietTimeout: 5, maxTimeout: 180, readAfterWrite: true),
        Command(name: "hum_content_crc", value: Data([0x08]), quietTimeout: 0.8, maxTimeout: 5, readAfterWrite: true)
    ]

    private var service: CBService?
    private var configCharacteristic: CBCharacteristic?
    private var allDiscoveredCharacteristics: [CBCharacteristic] = []
    private var transferMode: TransferMode = .readOnlySnapshot
    private var commandAttempts: [CommandAttempt] = []
    private var notifyCharacteristics: [CBCharacteristic] = []
    private var configData: Data?
    private var commandAttemptIndex = 0
    private var currentAttempt: CommandAttempt?
    private var currentAttemptReceivedPacket = false
    private var packets: [InkbirdHistoryPacket] = []
    private var characteristics: [InkbirdGATTCharacteristicInfo] = []
    private var warnings: [String] = []
    private var quietTimer: Timer?
    private var maxTimer: Timer?
    private var operationTimer: Timer?
    private var completed = false
    private var pendingCharacteristicServiceUUIDs: Set<String> = []
    private var pendingInitialReadKeys: Set<String> = []
    private var pendingNotificationKeys: Set<String> = []
    private var hasStartedCommands = false
    private var modeName = "read-only-gatt-snapshot"
    private var shouldDecodeHistory = false

    init(
        centralManager: CBCentralManager,
        peripheral: CBPeripheral,
        peripheralDelegate: CBPeripheralDelegate,
        latestReading: InkbirdReading,
        completion: @escaping (Result<InkbirdHistoryResult, Error>) -> Void
    ) {
        self.centralManager = centralManager
        self.peripheral = peripheral
        self.peripheralDelegate = peripheralDelegate
        self.latestReading = latestReading
        self.completion = completion
    }

    func start() {
        BirdMenuLog.debugData("history.operation connect id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "-")")
        peripheral.delegate = nil
        centralManager.connect(peripheral)
        operationTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { [weak self] _ in
            self?.fail(HistoryFetchError.timedOut("history operation"))
        }
    }

    func didConnect(_ peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral.identifier else {
            return
        }
        peripheral.delegate = peripheralDelegate
        BirdMenuLog.debugData("history.operation discoverServices id=\(peripheral.identifier.uuidString) scope=all")
        peripheral.discoverServices(nil)
    }

    func didDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral.identifier, !completed else {
            return
        }
        if !packets.isEmpty {
            warnings.append("The device disconnected during history fetch. Saved the partial raw dump captured before disconnect.")
            finish()
            return
        }
        fail(error ?? HistoryFetchError.disconnected)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            fail(error)
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            fail(HistoryFetchError.serviceNotFound)
            return
        }
        self.service = services.first(where: { $0.uuid == Self.inkbirdServiceUUID })
        pendingCharacteristicServiceUUIDs = Set(services.map { $0.uuid.uuidString })
        BirdMenuLog.debugData("history.operation services=\(services.map { $0.uuid.uuidString }.joined(separator: ","))")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            pendingCharacteristicServiceUUIDs.remove(service.uuid.uuidString)
            warnings.append("Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
            if pendingCharacteristicServiceUUIDs.isEmpty {
                configureHistoryTransferIfReady(peripheral: peripheral)
            }
            return
        }

        let discovered = service.characteristics ?? []
        allDiscoveredCharacteristics.append(contentsOf: discovered)
        characteristics.append(contentsOf: discovered.map { characteristic in
            InkbirdGATTCharacteristicInfo(
                serviceUUID: service.uuid.uuidString,
                characteristicUUID: characteristic.uuid.uuidString,
                properties: characteristic.properties.names,
                valueHex: nil
            )
        })
        BirdMenuLog.debugData("history.operation serviceCharacteristics service=\(service.uuid.uuidString) chars=\(discovered.map { "\($0.uuid.uuidString)[\($0.properties.names.joined(separator: ","))]" }.joined(separator: " "))")

        pendingCharacteristicServiceUUIDs.remove(service.uuid.uuidString)
        if pendingCharacteristicServiceUUIDs.isEmpty {
            configureHistoryTransferIfReady(peripheral: peripheral)
        }
    }

    private func configureHistoryTransferIfReady(peripheral: CBPeripheral) {
        BirdMenuLog.debugData("history.operation characteristics=\(characteristics.map { "\($0.characteristicUUID)[\($0.properties.joined(separator: ","))]" }.joined(separator: " "))")
        configCharacteristic = allDiscoveredCharacteristics.first {
            $0.uuid == Self.configCharacteristicUUID || $0.uuid == Self.ith11BConfigCharacteristicUUID
        }
        if let historyCharacteristic = allDiscoveredCharacteristics.first(where: { $0.uuid == Self.historyCharacteristicUUID }) {
            transferMode = .legacyFFF8(historyCharacteristic)
            modeName = "fff8-history"
            shouldDecodeHistory = true
        } else if let ith11BCommandCharacteristic = allDiscoveredCharacteristics.first(where: { $0.uuid == Self.ith11BCommandCharacteristicUUID }),
                  let ith11BClockCharacteristic = allDiscoveredCharacteristics.first(where: { $0.uuid == Self.ith11BClockCharacteristicUUID }) {
            transferMode = .ith11BTrace(config: ith11BCommandCharacteristic, clock: ith11BClockCharacteristic)
            modeName = "ith11b-official-trace"
            shouldDecodeHistory = true
            warnings.append(
                "Using the experimental offline-history command sequence observed from a compatible sensor app trace."
            )
        } else {
            transferMode = .readOnlySnapshot
            modeName = "read-only-gatt-snapshot"
            shouldDecodeHistory = false
            warnings.append(
                "FFF8 was not found on this sensor. Saved a full GATT snapshot without writing unknown history commands."
            )
            BirdMenuLog.debugData("history.operation noHistoryCommandMode mode=readOnlyGattSnapshot")
        }
        notifyCharacteristics = allDiscoveredCharacteristics.filter {
            $0.uuid == Self.notifyCharacteristicUUID || $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }

        let readableCharacteristics = allDiscoveredCharacteristics.filter { $0.properties.contains(.read) }
        pendingInitialReadKeys = Set(readableCharacteristics.map(characteristicKey))
        for characteristic in readableCharacteristics {
            BirdMenuLog.debugData("history.operation readInitial char=\(characteristic.uuid.uuidString)")
            peripheral.readValue(for: characteristic)
        }

        for characteristic in notifyCharacteristics {
            BirdMenuLog.debugData("history.operation enableNotify char=\(characteristic.uuid.uuidString)")
            peripheral.setNotifyValue(true, for: characteristic)
        }
        pendingNotificationKeys = Set(notifyCharacteristics.map(characteristicKey))
        if notifyCharacteristics.isEmpty {
            warnings.append("No notifying characteristic was found; fff8 reads may still produce data, but history notifications are unlikely.")
        }
        startCommandsIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            warnings.append("Could not enable notifications for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        }
        pendingNotificationKeys.remove(characteristicKey(characteristic))
        startCommandsIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let readKey = characteristicKey(characteristic)
        let wasPendingInitialRead = pendingInitialReadKeys.remove(readKey) != nil
        if let error {
            warnings.append("Read/update failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            if wasPendingInitialRead {
                startCommandsIfReady()
            }
            return
        }
        guard let value = characteristic.value else {
            if wasPendingInitialRead {
                startCommandsIfReady()
            }
            return
        }

        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            pendingNotificationKeys.remove(characteristicKey(characteristic))
        }

        if characteristic.uuid == Self.configCharacteristicUUID || characteristic.uuid == Self.ith11BConfigCharacteristicUUID {
            configData = value
            BirdMenuLog.debugData("history.config hex=\(value.hexString) interval=\(InkbirdHistoryExportWriter.intervalSeconds(from: value).map(String.init) ?? "-")")
            updateCharacteristicValue(characteristic, value: value)
            if wasPendingInitialRead {
                startCommandsIfReady()
                return
            }
        }
        updateCharacteristicValue(characteristic, value: value)

        let commandName = currentAttempt?.command.name ?? "initial_or_unsolicited"
        packets.append(
            InkbirdHistoryPacket(
                command: commandName,
                characteristicUUID: characteristic.uuid.uuidString,
                timestamp: Date(),
                hex: value.hexString
            )
        )
        BirdMenuLog.debugData("history.packet command=\(commandName) char=\(characteristic.uuid.uuidString) bytes=\(value.count) hex=\(value.hexString)")
        if wasPendingInitialRead {
            startCommandsIfReady()
        } else {
            currentAttemptReceivedPacket = true
            scheduleQuietTimer()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            warnings.append("Write failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            finishCurrentCommand()
            return
        }

        if currentAttempt?.command.readAfterWrite == true, characteristic.properties.contains(.read), !completed {
            peripheral.readValue(for: characteristic)
        }
    }

    func fail(_ error: Error) {
        guard !completed else {
            return
        }
        completed = true
        invalidateTimers()
        operationTimer?.invalidate()
        operationTimer = nil
        BirdMenuLog.debugData("history.operation fail error=\(error.localizedDescription)")
        completion(.failure(error))
    }

    private func startCommandsIfReady() {
        guard !hasStartedCommands, pendingNotificationKeys.isEmpty, pendingInitialReadKeys.isEmpty else {
            return
        }
        hasStartedCommands = true
        switch transferMode {
        case .readOnlySnapshot:
            warnings.append("No writable characteristic was available for a history probe. Saved discovered GATT metadata only.")
            finish()
            return
        case let .legacyFFF8(characteristic):
            commandAttempts = historyCommands.map { CommandAttempt(command: $0, characteristic: characteristic) }
        case let .ith11BTrace(configCharacteristic, clockCharacteristic):
            commandAttempts = ith11BTraceCommandAttempts(
                configCharacteristic: configCharacteristic,
                clockCharacteristic: clockCharacteristic
            )
        }
        BirdMenuLog.debugData(
            "history.operation commandMode=\(modeName) attempts=\(commandAttempts.map { "\($0.command.name)@\($0.characteristic.uuid.uuidString)" }.joined(separator: ","))"
        )
        writeNextCommand()
    }

    private func writeNextCommand() {
        invalidateTimers()
        guard commandAttemptIndex < commandAttempts.count else {
            finish()
            return
        }

        let attempt = commandAttempts[commandAttemptIndex]
        commandAttemptIndex += 1
        currentAttempt = attempt
        currentAttemptReceivedPacket = false
        let command = attempt.command
        let characteristic = attempt.characteristic
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        BirdMenuLog.debugData("history.command write name=\(command.name) value=\(command.value.hexString) char=\(characteristic.uuid.uuidString) type=\(writeType == .withResponse ? "withResponse" : "withoutResponse")")
        peripheral.writeValue(command.value, for: characteristic, type: writeType)
        if writeType == .withoutResponse {
            if command.readAfterWrite, characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            } else {
                scheduleQuietTimer()
            }
        }
        maxTimer = Timer.scheduledTimer(withTimeInterval: command.maxTimeout, repeats: false) { [weak self] _ in
            self?.warnings.append("Timed out while waiting for \(command.name); continuing with the next command.")
            BirdMenuLog.debugData("history.command maxTimeout name=\(command.name)")
            self?.finishCurrentCommand()
        }
    }

    private func scheduleQuietTimer() {
        quietTimer?.invalidate()
        guard let currentAttempt else {
            return
        }
        guard currentAttemptReceivedPacket || !currentAttempt.command.readAfterWrite else {
            return
        }
        quietTimer = Timer.scheduledTimer(withTimeInterval: currentAttempt.command.quietTimeout, repeats: false) { [weak self] _ in
            if let commandName = self?.currentAttempt?.command.name {
                BirdMenuLog.debugData("history.command quietTimeout name=\(commandName)")
            }
            self?.finishCurrentCommand()
        }
    }

    private func finishCurrentCommand() {
        invalidateTimers()
        currentAttempt = nil
        writeNextCommand()
    }

    private func finish() {
        guard !completed else {
            return
        }
        completed = true
        invalidateTimers()
        operationTimer?.invalidate()
        operationTimer = nil
        do {
            let result = try InkbirdHistoryExportWriter.write(
                deviceName: latestReading.deviceName,
                peripheralID: latestReading.peripheralID,
                latestReading: latestReading,
                config: configData,
                characteristics: characteristics,
                packets: packets,
                warnings: warnings,
                mode: modeName,
                decodeHistory: shouldDecodeHistory
            )
            BirdMenuLog.debugData("history.operation wrote raw=\(result.rawURL.path) csv=\(result.csvURL?.path ?? "-") packets=\(result.packetCount) records=\(result.recordCount)")
            completion(.success(result))
        } catch {
            completion(.failure(error))
        }
    }

    private func invalidateTimers() {
        quietTimer?.invalidate()
        quietTimer = nil
        maxTimer?.invalidate()
        maxTimer = nil
    }

    private func updateCharacteristicValue(_ characteristic: CBCharacteristic, value: Data) {
        characteristics = characteristics.map {
            guard $0.characteristicUUID == characteristic.uuid.uuidString else {
                return $0
            }
            return InkbirdGATTCharacteristicInfo(
                serviceUUID: $0.serviceUUID,
                characteristicUUID: $0.characteristicUUID,
                properties: $0.properties,
                valueHex: value.hexString
            )
        }
    }

    private func characteristicKey(_ characteristic: CBCharacteristic) -> String {
        "\(characteristic.service?.uuid.uuidString ?? "-")/\(characteristic.uuid.uuidString)"
    }

    private func ith11BTraceCommandAttempts(
        configCharacteristic: CBCharacteristic,
        clockCharacteristic: CBCharacteristic
    ) -> [CommandAttempt] {
        [
            CommandAttempt(
                command: Command(
                    name: "ith11b_set_clock",
                    value: InkbirdITH11BHistoryProtocol.timestampCommand(),
                    quietTimeout: 0.05,
                    maxTimeout: 5,
                    readAfterWrite: false
                ),
                characteristic: clockCharacteristic
            ),
            CommandAttempt(
                command: Command(
                    name: "ith11b_history_command_02",
                    value: Data([0x02]),
                    quietTimeout: 0.05,
                    maxTimeout: 10,
                    readAfterWrite: false
                ),
                characteristic: configCharacteristic
            ),
            CommandAttempt(
                command: Command(
                    name: "ith11b_history_command_01",
                    value: Data([0x01]),
                    quietTimeout: 8,
                    maxTimeout: 600,
                    readAfterWrite: false
                ),
                characteristic: configCharacteristic
            ),
            CommandAttempt(
                command: Command(
                    name: "ith11b_history_command_04",
                    value: Data([0x04]),
                    quietTimeout: 3,
                    maxTimeout: 60,
                    readAfterWrite: false
                ),
                characteristic: configCharacteristic
            )
        ]
    }
}

private extension CBCharacteristicProperties {
    var names: [String] {
        var values: [String] = []
        if contains(.broadcast) { values.append("broadcast") }
        if contains(.read) { values.append("read") }
        if contains(.writeWithoutResponse) { values.append("writeWithoutResponse") }
        if contains(.write) { values.append("write") }
        if contains(.notify) { values.append("notify") }
        if contains(.indicate) { values.append("indicate") }
        if contains(.authenticatedSignedWrites) { values.append("authenticatedSignedWrites") }
        if contains(.extendedProperties) { values.append("extendedProperties") }
        if contains(.notifyEncryptionRequired) { values.append("notifyEncryptionRequired") }
        if contains(.indicateEncryptionRequired) { values.append("indicateEncryptionRequired") }
        return values
    }
}
