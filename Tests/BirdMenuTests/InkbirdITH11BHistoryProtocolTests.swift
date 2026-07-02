import Foundation
import Testing
@testable import BirdMenu

@Test func buildsTimestampCommandLikeOfficialTrace() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let date = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 25,
        hour: 21,
        minute: 56,
        second: 3
    )))

    let command = InkbirdITH11BHistoryProtocol.timestampCommand(for: date, calendar: calendar)

    #expect(command.hexString == "033815041906ea07a327")
}

@Test func decodesITH11BConfigIntervalFromFFF5() {
    let config = Data(hexString: "00000000002c010000000058029cff200364000401c8")

    #expect(InkbirdHistoryExportWriter.intervalSeconds(from: config) == 300)
}

@Test func decodesITH11BHistoryPayload() throws {
    let packet = InkbirdHistoryPacket(
        command: "ith11b_history_command_01",
        characteristicUUID: "FFF6",
        timestamp: Date(timeIntervalSince1970: 1_000),
        hex: "fd006f02fd006f02fd006d02fd006f02fd007502fd007902fd007d0200000000"
    )
    let latest = InkbirdReading(
        model: "ITH-11-B",
        deviceName: "ITH-11-B",
        peripheralID: UUID(),
        temperatureCelsius: 25.3,
        humidityPercent: 63.7,
        batteryPercent: 100,
        rssi: -50,
        date: Date(timeIntervalSince1970: 10_000),
        advertisementHex: ""
    )

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: [packet],
        intervalSeconds: 60,
        latestReading: latest
    )

    #expect(records.count == 7)
    #expect(records.first?.temperatureCelsius == 25.3)
    #expect(records.first?.humidityPercent == 62.3)
    #expect(records.last?.humidityPercent == 63.7)
    #expect(records.first?.timestamp == Date(timeIntervalSince1970: 9_640))
    #expect(records.last?.timestamp == Date(timeIntervalSince1970: 10_000))
}

@Test func decodesITH11BHistoryPayloadAcrossNotificationBoundaries() {
    let packets = [
        InkbirdHistoryPacket(
            command: "ith11b_history_command_01",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_000),
            hex: "fd006f02fd"
        ),
        InkbirdHistoryPacket(
            command: "ith11b_history_command_01",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_001),
            hex: "006d0200000000"
        )
    ]

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: nil,
        latestReading: nil
    )

    #expect(records.count == 2)
    #expect(records[0].temperatureCelsius == 25.3)
    #expect(records[0].humidityPercent == 62.3)
    #expect(records[1].temperatureCelsius == 25.3)
    #expect(records[1].humidityPercent == 62.1)
}

@Test func decodesITH11BHistoryPacketsWithTwoByteTrailers() {
    let packets = [
        InkbirdHistoryPacket(
            command: "ith11b_history_command_01",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_000),
            hex: String(repeating: "e400b103", count: 45) + "0100"
        ),
        InkbirdHistoryPacket(
            command: "ith11b_history_command_01",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_001),
            hex: String(repeating: "e500e303", count: 45) + "0200"
        )
    ]

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: nil,
        latestReading: nil
    )

    #expect(records.count == 90)
    #expect(records[44].temperatureCelsius == 22.8)
    #expect(records[44].humidityPercent == 94.5)
    #expect(records[45].temperatureCelsius == 22.9)
    #expect(records[45].humidityPercent == 99.5)
}

@Test func chartGroupsRecordsByLocalDayInProvidedTimeZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let june28 = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 23,
        minute: 59
    )))
    let june29 = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 29,
        hour: 0,
        minute: 0
    )))
    let records = [
        InkbirdHistoryRecord(timestamp: june29, index: 1, temperatureCelsius: 24.1, humidityPercent: 70.0),
        InkbirdHistoryRecord(timestamp: june28, index: 0, temperatureCelsius: 24.0, humidityPercent: 69.0)
    ]

    let groups = InkbirdHistoryChartRenderer.recordsByLocalDay(records, timeZone: calendar.timeZone)

    #expect(groups.count == 2)
    #expect(groups[0].dayStart == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
    )))
    #expect(groups[0].records.map(\.index) == [0])
    #expect(groups[1].dayStart == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 29,
    )))
    #expect(groups[1].records.map(\.index) == [1])
    #expect(InkbirdHistoryChartRenderer.fileName(forDayStartingAt: groups[0].dayStart, timeZone: calendar.timeZone) == "history_20260628.png")
    #expect(InkbirdHistoryChartRenderer.fileName(forDayStartingAt: groups[1].dayStart, timeZone: calendar.timeZone) == "history_20260629.png")
}

@Test func chartDayDomainCoversWholeLocalDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let date = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 11,
        minute: 34
    )))

    let domain = InkbirdHistoryChartRenderer.dayTimeDomain(startingAt: date, timeZone: calendar.timeZone)

    #expect(domain.start == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28
    )))
    #expect(domain.end == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 23,
        minute: 59,
        second: 59
    )))
}

@Test func writesHistoryPNGsPerLocalDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let june28 = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 23,
        minute: 50
    )))
    let june29 = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 29,
        hour: 0,
        minute: 10
    )))
    let records = [
        InkbirdHistoryRecord(timestamp: june28, index: 0, temperatureCelsius: 24.0, humidityPercent: 69.0),
        InkbirdHistoryRecord(timestamp: june29, index: 1, temperatureCelsius: 24.1, humidityPercent: 70.0)
    ]
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("BirdMenuTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: folder)
    }

    let urls = try InkbirdHistoryChartRenderer.writePNGs(for: records, to: folder, timeZone: calendar.timeZone)

    #expect(urls.map(\.lastPathComponent) == ["history_20260628.png", "history_20260629.png"])
    for url in urls {
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data([0x89, 0x50, 0x4e, 0x47])))
    }
}

@Test func decodesITH11BInitialRTDTHHistoryWithFallbackIntervalAndDeduplication() {
    let rtdthHex = "7274647468de00e703610084080000000000e703"
        + String(repeating: "e500e703", count: 14)
        + String(repeating: "0000", count: 50)
        + "0300"
    let packets = [
        InkbirdHistoryPacket(
            command: "initial_or_unsolicited",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_000),
            hex: rtdthHex
        ),
        InkbirdHistoryPacket(
            command: "initial_or_unsolicited",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_001),
            hex: rtdthHex
        )
    ]
    let latest = InkbirdReading(
        model: "ITH-11-B",
        deviceName: "ITH-11-B",
        peripheralID: UUID(),
        temperatureCelsius: 22.2,
        humidityPercent: 99.9,
        batteryPercent: 97,
        rssi: -86,
        date: Date(timeIntervalSince1970: 10_000),
        advertisementHex: ""
    )

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: nil,
        latestReading: latest
    )

    #expect(records.count == 14)
    #expect(records.first?.temperatureCelsius == 22.9)
    #expect(records.first?.humidityPercent == 99.9)
    #expect(records.first?.timestamp == Date(timeIntervalSince1970: 9_220))
    #expect(records.last?.timestamp == Date(timeIntervalSince1970: 10_000))
}

@Test func chartHumidityAxisFixesUpperBoundAtOneHundredPercent() {
    let range = InkbirdHistoryChartRenderer.humidityAxisRange(values: [99.9, 99.9, 99.9])

    #expect(range.lower == 99.7)
    #expect(range.upper == 100.0)
}

@Test func chartTemperatureAxisUsesPaddedNiceRange() {
    let range = InkbirdHistoryChartRenderer.temperatureAxisRange(values: [22.9, 24.1])

    #expect(range.lower == 22.6)
    #expect(abs(range.upper - 24.4) < 0.0001)
}

@Test func rendersHistoryPNG() throws {
    let records = [
        InkbirdHistoryRecord(timestamp: Date(timeIntervalSince1970: 1_000), index: 0, temperatureCelsius: 24.1, humidityPercent: 99.9),
        InkbirdHistoryRecord(timestamp: Date(timeIntervalSince1970: 1_060), index: 1, temperatureCelsius: 24.0, humidityPercent: 99.9),
        InkbirdHistoryRecord(timestamp: Date(timeIntervalSince1970: 1_120), index: 2, temperatureCelsius: 23.9, humidityPercent: 99.9)
    ]

    let data = try #require(try InkbirdHistoryChartRenderer.pngData(for: records))

    #expect(data.starts(with: Data([0x89, 0x50, 0x4e, 0x47])))
}
