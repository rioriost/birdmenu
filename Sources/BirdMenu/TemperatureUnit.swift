import Foundation

enum TemperatureUnit: String {
    case celsius
    case fahrenheit

    static let defaultsKey = "temperatureUnit"

    static var current: TemperatureUnit {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
                  let unit = TemperatureUnit(rawValue: rawValue) else {
                return .celsius
            }
            return unit
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    func formatted(_ celsiusValue: Double) -> String {
        switch self {
        case .celsius:
            return String(format: "%.1f°C", celsiusValue)
        case .fahrenheit:
            return String(format: "%.1f°F", celsiusValue * 9 / 5 + 32)
        }
    }
}
