import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct InkbirdHistoryResult {
    let folderURL: URL
    let rawURL: URL
    let csvURL: URL?
    let pngURLs: [URL]
    let recordCount: Int
    let packetCount: Int
    let warnings: [String]
}

struct InkbirdHistoryPacket: Codable {
    let command: String
    let characteristicUUID: String
    let timestamp: Date
    let hex: String
}

struct InkbirdGATTCharacteristicInfo: Codable {
    let serviceUUID: String
    let characteristicUUID: String
    let properties: [String]
    let valueHex: String?
}

struct InkbirdHistoryRawDump: Codable {
    let deviceName: String
    let peripheralID: String
    let fetchedAt: Date
    let mode: String
    let latestReading: LatestReadingSnapshot?
    let configHex: String?
    let intervalSeconds: Int?
    let characteristics: [InkbirdGATTCharacteristicInfo]
    let packets: [InkbirdHistoryPacket]
    let warnings: [String]

    struct LatestReadingSnapshot: Codable {
        let temperatureCelsius: Double
        let humidityPercent: Double?
        let batteryPercent: Int
        let rssi: Int
        let date: Date
    }
}

struct InkbirdHistoryRecord {
    let timestamp: Date?
    let index: Int
    let temperatureCelsius: Double?
    let humidityPercent: Double?
}

enum InkbirdHistoryExportWriter {
    private static let ith11BFallbackIntervalSeconds = 60

    static func write(
        deviceName: String,
        peripheralID: UUID,
        latestReading: InkbirdReading?,
        config: Data?,
        characteristics: [InkbirdGATTCharacteristicInfo],
        packets: [InkbirdHistoryPacket],
        warnings: [String],
        mode: String = "fff8-history",
        decodeHistory: Bool = true
    ) throws -> InkbirdHistoryResult {
        let folder = try outputFolder(deviceName: deviceName, peripheralID: peripheralID)
        let interval = intervalSeconds(from: config)
        let rawDump = InkbirdHistoryRawDump(
            deviceName: deviceName,
            peripheralID: peripheralID.uuidString,
            fetchedAt: Date(),
            mode: mode,
            latestReading: latestReading.map {
                InkbirdHistoryRawDump.LatestReadingSnapshot(
                    temperatureCelsius: $0.temperatureCelsius,
                    humidityPercent: $0.humidityPercent,
                    batteryPercent: $0.batteryPercent,
                    rssi: $0.rssi,
                    date: $0.date
                )
            },
            configHex: config?.hexString,
            intervalSeconds: interval,
            characteristics: characteristics,
            packets: packets,
            warnings: warnings
        )

        let rawURL = folder.appendingPathComponent("raw-history.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rawDump).write(to: rawURL, options: .atomic)

        let records = decodeHistory
            ? decodeRecords(
                packets: packets,
                intervalSeconds: interval,
                latestReading: latestReading,
                mode: mode
            )
            : []
        let csvURL: URL?
        let pngURLs: [URL]
        if records.contains(where: { $0.temperatureCelsius != nil || $0.humidityPercent != nil }) {
            let csv = folder.appendingPathComponent("history.csv")
            try Self.csv(for: records).write(to: csv, atomically: true, encoding: .utf8)
            csvURL = csv

            pngURLs = try InkbirdHistoryChartRenderer.writePNGs(for: records, to: folder)
        } else {
            csvURL = nil
            pngURLs = []
        }

        return InkbirdHistoryResult(
            folderURL: folder,
            rawURL: rawURL,
            csvURL: csvURL,
            pngURLs: pngURLs,
            recordCount: records.count,
            packetCount: packets.count,
            warnings: warnings
        )
    }

    static func intervalSeconds(from config: Data?) -> Int? {
        guard let config, config.count >= 9 else {
            return nil
        }
        for offset in [5, 7] where offset + 1 < config.count {
            let value = Int(config[offset]) | (Int(config[offset + 1]) << 8)
            if (1...86_400).contains(value) {
                return value
            }
        }
        return nil
    }

    private static func outputFolder(deviceName: String, peripheralID: UUID) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("BirdMenu Logs", isDirectory: true)
        let stamp = ISO8601DateFormatter.fileSafe.fileSafeString(from: Date())
        let shortID = peripheralID.uuidString.replacingOccurrences(of: "-", with: "").suffix(6).uppercased()
        let folder = root.appendingPathComponent("\(stamp)-Sensor-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func decodeRecords(
        packets: [InkbirdHistoryPacket],
        intervalSeconds: Int?,
        latestReading: InkbirdReading?,
        mode: String
    ) -> [InkbirdHistoryRecord] {
        if mode == "ith11b-official-trace" {
            return decodeITH11BRecords(
                packets: packets,
                intervalSeconds: intervalSeconds,
                latestReading: latestReading
            )
        }

        let tempData = packets
            .filter { $0.command == "temp_content" }
            .compactMap { Data(hexString: $0.hex) }
            .reduce(Data(), +)
        let humData = packets
            .filter { $0.command == "hum_content" }
            .compactMap { Data(hexString: $0.hex) }
            .reduce(Data(), +)

        let temperatures = decodeSignedSeries(
            tempData,
            candidates: [10.0, 100.0],
            plausible: -60.0...100.0,
            target: latestReading?.temperatureCelsius
        )
        let humidities = decodeUnsignedSeries(
            humData,
            candidates: [10.0, 100.0],
            plausible: 0.0...100.0,
            target: latestReading?.humidityPercent
        )

        let count = max(temperatures.count, humidities.count)
        guard count > 0 else {
            return []
        }

        let anchor = Date()
        return (0..<count).map { index in
            let timestamp = intervalSeconds.map { interval in
                anchor.addingTimeInterval(-Double(count - 1 - index) * Double(interval))
            }
            return InkbirdHistoryRecord(
                timestamp: timestamp,
                index: index,
                temperatureCelsius: index < temperatures.count ? temperatures[index] : nil,
                humidityPercent: index < humidities.count ? humidities[index] : nil
            )
        }
    }

    static func decodeITH11BRecords(
        packets: [InkbirdHistoryPacket],
        intervalSeconds: Int?,
        latestReading: InkbirdReading?
    ) -> [InkbirdHistoryRecord] {
        let records = decodeITH11BPacketRecords(packets)

        guard !records.isEmpty else {
            return []
        }

        let anchor = latestReading?.date ?? Date()
        let effectiveInterval = intervalSeconds ?? ith11BFallbackIntervalSeconds
        return records.enumerated().map { index, pair in
            return InkbirdHistoryRecord(
                timestamp: anchor.addingTimeInterval(-Double(records.count - 1 - index) * Double(effectiveInterval)),
                index: index,
                temperatureCelsius: pair.temperatureCelsius,
                humidityPercent: pair.humidityPercent
            )
        }
    }

    private static func decodeITH11BPacketRecords(_ packets: [InkbirdHistoryPacket]) -> [(temperatureCelsius: Double, humidityPercent: Double)] {
        let commandData = packets
            .filter { $0.command == "ith11b_history_command_01" }
            .compactMap { Data(hexString: $0.hex) }
            .map(ith11BRecordPayload)
            .reduce(Data(), +)
        let commandRecords = decodeITH11BPayload(commandData)
        if !commandRecords.isEmpty {
            return commandRecords
        }

        var seenPayloads: Set<Data> = []
        var records: [(temperatureCelsius: Double, humidityPercent: Double)] = []
        for payload in packets
            .filter({ $0.characteristicUUID.caseInsensitiveCompare("FFF6") == .orderedSame })
            .compactMap({ Data(hexString: $0.hex) })
            .compactMap(ith11BRTDTHRecordPayload)
        {
            guard seenPayloads.insert(payload).inserted else {
                continue
            }
            records.append(contentsOf: decodeITH11BPayload(payload))
        }
        return records
    }

    private static func decodeITH11BPayload(_ data: Data) -> [(temperatureCelsius: Double, humidityPercent: Double)] {
        guard data.count >= 4 else {
            return []
        }

        var records: [(temperatureCelsius: Double, humidityPercent: Double)] = []
        var index = 0
        while index + 3 < data.count {
            let temperatureRaw = Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
            let humidityRaw = UInt16(data[index + 2]) | (UInt16(data[index + 3]) << 8)

            if temperatureRaw == 0, humidityRaw == 0 {
                break
            }

            let temperature = Double(temperatureRaw) / 10.0
            let humidity = Double(humidityRaw) / 10.0
            guard (-60.0...100.0).contains(temperature), (0.0...100.0).contains(humidity) else {
                break
            }

            records.append((temperature, humidity))
            index += 4
        }
        return records
    }

    private static func ith11BRecordPayload(_ data: Data) -> Data {
        // Observed compatible-sensor history notifications carry 4-byte records followed
        // by a 2-byte packet trailer. Drop the trailer before concatenating
        // notifications; otherwise the next packet is decoded two bytes out of
        // phase and temperature/humidity appear swapped.
        guard data.count > 4, data.count % 4 == 2 else {
            return data
        }
        return Data(data.dropLast(2))
    }

    private static func ith11BRTDTHRecordPayload(_ data: Data) -> Data? {
        let magic = Data([0x72, 0x74, 0x64, 0x74, 0x68])
        let recordOffset = 20
        guard data.starts(with: magic), data.count >= recordOffset + 4 else {
            return nil
        }

        var payload = Data()
        var index = recordOffset
        while index + 3 < data.count {
            let temperatureRaw = Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
            let humidityRaw = UInt16(data[index + 2]) | (UInt16(data[index + 3]) << 8)
            if temperatureRaw == 0, humidityRaw == 0 {
                break
            }
            let temperature = Double(temperatureRaw) / 10.0
            let humidity = Double(humidityRaw) / 10.0
            guard (-60.0...100.0).contains(temperature), (0.0...100.0).contains(humidity) else {
                return nil
            }
            payload.append(contentsOf: data[index..<(index + 4)])
            index += 4
        }
        return payload.isEmpty ? nil : payload
    }

    private static func decodeSignedSeries(
        _ data: Data,
        candidates: [Double],
        plausible: ClosedRange<Double>,
        target: Double?
    ) -> [Double] {
        candidates
            .map { scale in
                decodePairs(data) { pair in
                    let raw = Int16(bitPattern: UInt16(pair.0) | (UInt16(pair.1) << 8))
                    return Double(raw) / scale
                }
            }
            .max { score($0, plausible: plausible, target: target) < score($1, plausible: plausible, target: target) } ?? []
    }

    private static func decodeUnsignedSeries(
        _ data: Data,
        candidates: [Double],
        plausible: ClosedRange<Double>,
        target: Double?
    ) -> [Double] {
        candidates
            .map { scale in
                decodePairs(data) { pair in
                    let raw = UInt16(pair.0) | (UInt16(pair.1) << 8)
                    return Double(raw) / scale
                }
            }
            .max { score($0, plausible: plausible, target: target) < score($1, plausible: plausible, target: target) } ?? []
    }

    private static func decodePairs(_ data: Data, transform: ((UInt8, UInt8)) -> Double) -> [Double] {
        guard data.count >= 2 else {
            return []
        }
        var values: [Double] = []
        var index = 0
        while index + 1 < data.count {
            values.append(transform((data[index], data[index + 1])))
            index += 2
        }
        return values
    }

    private static func score(_ values: [Double], plausible: ClosedRange<Double>, target: Double?) -> Double {
        guard !values.isEmpty else {
            return -Double.greatestFiniteMagnitude
        }
        let plausibleValues = values.filter { plausible.contains($0) }
        var score = Double(plausibleValues.count) / Double(values.count)
        if let target, let last = plausibleValues.last {
            score += max(0, 1.0 - abs(last - target) / 20.0)
        }
        return score
    }

    private static func csv(for records: [InkbirdHistoryRecord]) -> String {
        var lines = ["timestamp,index,temperature_c,humidity_percent"]
        let formatter = ISO8601DateFormatter()
        for record in records {
            lines.append([
                record.timestamp.map { formatter.string(from: $0) } ?? "",
                String(record.index),
                record.temperatureCelsius.map { String(format: "%.2f", $0) } ?? "",
                record.humidityPercent.map { String(format: "%.2f", $0) } ?? ""
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum InkbirdHistoryChartRenderer {
    private static let width = 1_500
    private static let height = 860
    private static let marginLeft: CGFloat = 120
    private static let marginRight: CGFloat = 125
    private static let marginTop: CGFloat = 160
    private static let marginBottom: CGFloat = 105

    struct TimeDomain: Equatable {
        let start: Date
        let end: Date
    }

    struct ValueRange: Equatable {
        let lower: Double
        let upper: Double
    }

    static func writePNGs(
        for records: [InkbirdHistoryRecord],
        to folder: URL,
        timeZone: TimeZone = .autoupdatingCurrent
    ) throws -> [URL] {
        var urls: [URL] = []
        for group in recordsByLocalDay(records, timeZone: timeZone) {
            let domain = dayTimeDomain(startingAt: group.dayStart, timeZone: timeZone)
            guard let pngData = try pngData(for: group.records, timeZone: timeZone, timeDomain: domain) else {
                continue
            }
            let url = folder.appendingPathComponent(fileName(forDayStartingAt: group.dayStart, timeZone: timeZone))
            try pngData.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    static func recordsByLocalDay(
        _ records: [InkbirdHistoryRecord],
        timeZone: TimeZone
    ) -> [(dayStart: Date, records: [InkbirdHistoryRecord])] {
        let calendar = calendar(for: timeZone)
        var recordsByDay: [Date: [InkbirdHistoryRecord]] = [:]
        for record in records {
            guard let timestamp = record.timestamp else {
                continue
            }
            recordsByDay[calendar.startOfDay(for: timestamp), default: []].append(record)
        }
        return recordsByDay.keys.sorted().map { dayStart in
            let dayRecords = recordsByDay[dayStart] ?? []
            return (dayStart, dayRecords.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) })
        }
    }

    static func dayTimeDomain(startingAt dayStart: Date, timeZone: TimeZone) -> TimeDomain {
        let calendar = calendar(for: timeZone)
        let normalizedStart = calendar.startOfDay(for: dayStart)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: normalizedStart) ?? normalizedStart.addingTimeInterval(86_400)
        return TimeDomain(start: normalizedStart, end: nextDay.addingTimeInterval(-1))
    }

    static func fileName(forDayStartingAt dayStart: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return "history_\(formatter.string(from: dayStart)).png"
    }

    static func pngData(
        for records: [InkbirdHistoryRecord],
        timeZone: TimeZone = .autoupdatingCurrent,
        timeDomain: TimeDomain? = nil
    ) throws -> Data? {
        let points = records.compactMap { record -> ChartPoint? in
            guard let timestamp = record.timestamp else {
                return nil
            }
            return ChartPoint(
                timestamp: timestamp,
                temperatureCelsius: record.temperatureCelsius,
                humidityPercent: record.humidityPercent
            )
        }
        guard points.contains(where: { $0.temperatureCelsius != nil || $0.humidityPercent != nil }) else {
            return nil
        }

        let timeDomain = timeDomain ?? roundedTimeDomain(for: points.map(\.timestamp), timeZone: timeZone)
        let temperatureRange = temperatureAxisRange(values: points.compactMap(\.temperatureCelsius))
        let humidityRange = humidityAxisRange(values: points.compactMap(\.humidityPercent))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        drawChart(
            in: context,
            points: points,
            timeDomain: timeDomain,
            timeZone: timeZone,
            temperatureRange: temperatureRange,
            humidityRange: humidityRange
        )

        guard let image = context.makeImage(),
              let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    static func roundedTimeDomain(for dates: [Date], timeZone: TimeZone = .autoupdatingCurrent) -> TimeDomain {
        guard let first = dates.min(), let last = dates.max() else {
            let now = Date()
            return TimeDomain(start: now, end: now.addingTimeInterval(1_800))
        }

        let calendar = calendar(for: timeZone)
        let start = roundedHalfHour(for: first, calendar: calendar, direction: .down)
        let end = roundedHalfHour(for: last, calendar: calendar, direction: .up)
        if end > start {
            return TimeDomain(start: start, end: end)
        }
        return TimeDomain(start: start, end: start.addingTimeInterval(1_800))
    }

    static func temperatureAxisRange(values: [Double]) -> ValueRange {
        guard let minimum = values.min(), let maximum = values.max() else {
            return ValueRange(lower: 0, upper: 1)
        }
        let padded = paddedRange(minimum: minimum, maximum: maximum, minimumPadding: 0.1)
        return niceRange(minimum: padded.lowerBound, maximum: padded.upperBound, step: 0.2)
    }

    static func humidityAxisRange(values: [Double]) -> ValueRange {
        guard let minimum = values.min() else {
            return ValueRange(lower: 0, upper: 100)
        }
        let spread = max((values.max() ?? minimum) - minimum, 0)
        let padding = max(spread * 0.12, 0.2)
        let lower = max(0, floor((minimum - padding) * 10) / 10)
        if lower >= 100 {
            return ValueRange(lower: 99, upper: 100)
        }
        return ValueRange(lower: lower, upper: 100)
    }

    private static func drawChart(
        in context: CGContext,
        points: [ChartPoint],
        timeDomain: TimeDomain,
        timeZone: TimeZone,
        temperatureRange: ValueRange,
        humidityRange: ValueRange
    ) {
        let plotRect = CGRect(
            x: marginLeft,
            y: marginTop,
            width: CGFloat(width) - marginLeft - marginRight,
            height: CGFloat(height) - marginTop - marginBottom
        )
        let textColor = CGColor(red: 0.145, green: 0.188, blue: 0.267, alpha: 1)
        let mutedColor = CGColor(red: 0.4, green: 0.44, blue: 0.52, alpha: 1)
        let gridColor = CGColor(red: 0.86, green: 0.89, blue: 0.92, alpha: 1)
        let plotBackground = CGColor(red: 0.985, green: 0.988, blue: 0.996, alpha: 1)
        let temperatureColor = CGColor(red: 0.85, green: 0.29, blue: 0.34, alpha: 1)
        let humidityColor = CGColor(red: 0.12, green: 0.48, blue: 0.72, alpha: 1)

        drawText("Sensor History", in: context, at: CGPoint(x: marginLeft, y: 28), size: 28, weight: .bold, color: textColor)
        drawText(subtitle(for: points, timeZone: timeZone), in: context, at: CGPoint(x: marginLeft, y: 66), size: 16, weight: .regular, color: mutedColor)
        drawLegend(in: context, x: marginLeft, y: 108, color: temperatureColor, label: "Temperature (°C, left axis)")
        drawLegend(in: context, x: marginLeft + 330, y: 108, color: humidityColor, label: "Humidity (%, right axis)")

        context.setFillColor(plotBackground)
        context.fill(plotRect)
        context.setStrokeColor(CGColor(red: 0.72, green: 0.76, blue: 0.81, alpha: 1))
        context.setLineWidth(1)
        context.stroke(plotRect)

        drawText("Temperature (°C)", in: context, at: CGPoint(x: plotRect.minX, y: plotRect.minY - 28), size: 16, weight: .bold, color: textColor)
        drawText(
            "Humidity (%)",
            in: context,
            at: CGPoint(x: plotRect.maxX - textWidth("Humidity (%)", size: 16, weight: .bold), y: plotRect.minY - 28),
            size: 16,
            weight: .bold,
            color: textColor
        )

        drawTemperatureAxis(in: context, plotRect: plotRect, range: temperatureRange, gridColor: gridColor, textColor: textColor)
        drawHumidityAxis(in: context, plotRect: plotRect, range: humidityRange, textColor: textColor)
        drawTimeAxis(in: context, plotRect: plotRect, domain: timeDomain, timeZone: timeZone, gridColor: gridColor, textColor: textColor)

        strokeSeries(
            points.compactMap { point in
                point.temperatureCelsius.map { (point.timestamp, $0) }
            },
            in: context,
            plotRect: plotRect,
            timeDomain: timeDomain,
            valueRange: temperatureRange,
            color: temperatureColor
        )
        strokeSeries(
            points.compactMap { point in
                point.humidityPercent.map { (point.timestamp, $0) }
            },
            in: context,
            plotRect: plotRect,
            timeDomain: timeDomain,
            valueRange: humidityRange,
            color: humidityColor
        )

        let timeAxisLabel = "Time (\(timeZoneLabel(for: timeZone, date: timeDomain.start)))"
        drawText(
            timeAxisLabel,
            in: context,
            at: CGPoint(x: plotRect.midX - textWidth(timeAxisLabel, size: 15, weight: .regular) / 2, y: CGFloat(height) - 48),
            size: 15,
            weight: .regular,
            color: textColor
        )
        drawText(
            "Source: history.csv",
            in: context,
            at: CGPoint(x: marginLeft, y: CGFloat(height) - 24),
            size: 12,
            weight: .regular,
            color: mutedColor
        )
    }

    private static func drawTemperatureAxis(
        in context: CGContext,
        plotRect: CGRect,
        range: ValueRange,
        gridColor: CGColor,
        textColor: CGColor
    ) {
        for index in 0...6 {
            let value = range.lower + (range.upper - range.lower) * Double(index) / 6
            let y = yPosition(value: value, range: range, plotRect: plotRect)
            context.setStrokeColor(gridColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: plotRect.minX, y: y))
            context.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            context.strokePath()
            let label = String(format: "%.1f", value)
            drawText(label, in: context, at: CGPoint(x: plotRect.minX - textWidth(label, size: 14, weight: .regular) - 14, y: y - 8), size: 14, weight: .regular, color: textColor)
        }
    }

    private static func drawHumidityAxis(
        in context: CGContext,
        plotRect: CGRect,
        range: ValueRange,
        textColor: CGColor
    ) {
        for value in humidityTickValues(for: range) {
            let y = yPosition(value: value, range: range, plotRect: plotRect)
            drawText(String(format: "%.1f", value), in: context, at: CGPoint(x: plotRect.maxX + 14, y: y - 8), size: 14, weight: .regular, color: textColor)
        }
    }

    private static func drawTimeAxis(
        in context: CGContext,
        plotRect: CGRect,
        domain: TimeDomain,
        timeZone: TimeZone,
        gridColor: CGColor,
        textColor: CGColor
    ) {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"

        drawTimeLabel(formatter.string(from: domain.start), date: domain.start, in: context, plotRect: plotRect, domain: domain, textColor: textColor)
        drawTimeLabel(formatter.string(from: domain.end), date: domain.end, in: context, plotRect: plotRect, domain: domain, textColor: textColor)

        for date in wholeHours(in: domain, timeZone: timeZone) {
            let x = xPosition(date: date, domain: domain, plotRect: plotRect)
            context.setStrokeColor(gridColor)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: x, y: plotRect.maxY - 12))
            context.addLine(to: CGPoint(x: x, y: plotRect.maxY + 8))
            context.strokePath()
            drawTimeLabel(formatter.string(from: date), date: date, in: context, plotRect: plotRect, domain: domain, textColor: textColor)
        }
    }

    private static func drawTimeLabel(
        _ label: String,
        date: Date,
        in context: CGContext,
        plotRect: CGRect,
        domain: TimeDomain,
        textColor: CGColor
    ) {
        let x = xPosition(date: date, domain: domain, plotRect: plotRect)
        drawText(label, in: context, at: CGPoint(x: x - textWidth(label, size: 14, weight: .regular) / 2, y: plotRect.maxY + 24), size: 14, weight: .regular, color: textColor)
    }

    private static func strokeSeries(
        _ values: [(Date, Double)],
        in context: CGContext,
        plotRect: CGRect,
        timeDomain: TimeDomain,
        valueRange: ValueRange,
        color: CGColor
    ) {
        guard let first = values.first else {
            return
        }
        context.setStrokeColor(color)
        context.setLineWidth(3.5)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: CGPoint(
            x: xPosition(date: first.0, domain: timeDomain, plotRect: plotRect),
            y: yPosition(value: first.1, range: valueRange, plotRect: plotRect)
        ))
        for value in values.dropFirst() {
            context.addLine(to: CGPoint(
                x: xPosition(date: value.0, domain: timeDomain, plotRect: plotRect),
                y: yPosition(value: value.1, range: valueRange, plotRect: plotRect)
            ))
        }
        context.strokePath()
    }

    private static func drawLegend(in context: CGContext, x: CGFloat, y: CGFloat, color: CGColor, label: String) {
        context.setStrokeColor(color)
        context.setLineWidth(4)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + 42, y: y))
        context.strokePath()
        drawText(label, in: context, at: CGPoint(x: x + 52, y: y - 10), size: 16, weight: .semibold, color: CGColor(red: 0.145, green: 0.188, blue: 0.267, alpha: 1))
    }

    private static func subtitle(for points: [ChartPoint], timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dates = points.map(\.timestamp)
        guard let start = dates.min(), let end = dates.max() else {
            return "\(timeZoneLabel(for: timeZone)), 0 records"
        }
        return "\(timeZoneLabel(for: timeZone, date: start)), \(points.count) records, \(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    private static func drawText(
        _ string: String,
        in context: CGContext,
        at point: CGPoint,
        size: CGFloat,
        weight: FontWeight,
        color: CGColor
    ) {
        let font = CTFontCreateWithName(weight.fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.saveGState()
        context.textPosition = point
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -2 * point.y - size)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func textWidth(_ string: String, size: CGFloat, weight: FontWeight) -> CGFloat {
        let font = CTFontCreateWithName(weight.fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func xPosition(date: Date, domain: TimeDomain, plotRect: CGRect) -> CGFloat {
        let span = max(domain.end.timeIntervalSince(domain.start), 1)
        return plotRect.minX + CGFloat(date.timeIntervalSince(domain.start) / span) * plotRect.width
    }

    private static func yPosition(value: Double, range: ValueRange, plotRect: CGRect) -> CGFloat {
        let span = max(range.upper - range.lower, 0.1)
        return plotRect.maxY - CGFloat((value - range.lower) / span) * plotRect.height
    }

    private static func wholeHours(in domain: TimeDomain, timeZone: TimeZone) -> [Date] {
        let calendar = calendar(for: timeZone)
        let firstHour = calendar.nextDate(
            after: domain.start,
            matching: DateComponents(minute: 0, second: 0, nanosecond: 0),
            matchingPolicy: .nextTime
        )
        guard var date = firstHour else {
            return []
        }

        var dates: [Date] = []
        while date < domain.end {
            if date > domain.start {
                dates.append(date)
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: date) else {
                break
            }
            date = next
        }
        return dates
    }

    private static func calendar(for timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func timeZoneLabel(for timeZone: TimeZone, date: Date = Date()) -> String {
        timeZone.abbreviation(for: date) ?? timeZone.identifier
    }

    private static func humidityTickValues(for range: ValueRange) -> [Double] {
        let span = range.upper - range.lower
        guard span > 0 else {
            return [range.lower]
        }
        if span <= 1 {
            var values: [Double] = []
            var value = ceil(range.lower * 10) / 10
            while value <= range.upper + 0.0001 {
                values.append((value * 10).rounded() / 10)
                value += 0.1
            }
            if values.first.map({ abs($0 - range.lower) > 0.0001 }) ?? true {
                values.insert(range.lower, at: 0)
            }
            if values.last.map({ abs($0 - range.upper) > 0.0001 }) ?? true {
                values.append(range.upper)
            }
            return values
        }
        return (0...4).map { index in
            range.lower + span * Double(index) / 4
        }
    }

    private enum RoundingDirection {
        case down
        case up
    }

    private static func roundedHalfHour(for date: Date, calendar: Calendar, direction: RoundingDirection) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        let roundedMinute = minute < 30 ? 0 : 30
        var roundedComponents = components
        roundedComponents.minute = roundedMinute
        roundedComponents.second = 0
        roundedComponents.nanosecond = 0
        let rounded = calendar.date(from: roundedComponents) ?? date
        switch direction {
        case .down:
            return rounded > date ? calendar.date(byAdding: .minute, value: -30, to: rounded) ?? rounded : rounded
        case .up:
            return rounded < date ? calendar.date(byAdding: .minute, value: 30, to: rounded) ?? rounded : rounded
        }
    }

    private static func paddedRange(minimum: Double, maximum: Double, minimumPadding: Double) -> ClosedRange<Double> {
        if minimum == maximum {
            return (minimum - minimumPadding * 2)...(maximum + minimumPadding * 2)
        }
        let padding = max((maximum - minimum) * 0.12, minimumPadding)
        return (minimum - padding)...(maximum + padding)
    }

    private static func niceRange(minimum: Double, maximum: Double, step: Double) -> ValueRange {
        ValueRange(
            lower: floor(minimum / step) * step,
            upper: ceil(maximum / step) * step
        )
    }

    private struct ChartPoint {
        let timestamp: Date
        let temperatureCelsius: Double?
        let humidityPercent: Double?
    }

    private enum FontWeight {
        case regular
        case semibold
        case bold

        var fontName: String {
            switch self {
            case .regular:
                ".AppleSystemUIFont"
            case .semibold:
                ".AppleSystemUIFontSemibold"
            case .bold:
                ".AppleSystemUIFontBold"
            }
        }
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}

private extension ISO8601DateFormatter {
    static var fileSafe: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    func fileSafeString(from date: Date) -> String {
        string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }
}
