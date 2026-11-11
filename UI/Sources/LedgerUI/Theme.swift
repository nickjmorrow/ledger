import LedgerCore
import SwiftUI

/// Midnight Sun palette: navy surfaces, one sun-yellow accent. Dark only.
public enum Theme {
    public static let background = Color(hex: 0x0b1120)   // navy 950: content
    public static let bar = Color(hex: 0x0f172a)          // navy 900: sidebar, bars, sheets
    public static let card = Color(hex: 0x131d33)         // navy 850: cards, inputs
    public static let field = Color(hex: 0x18233d)        // navy 800
    public static let raised = Color(hex: 0x22304f)       // navy 700: selected and hovered rows
    public static let line = Color(hex: 0x2e3f63)         // navy 600: separators

    public static let text = Color(hex: 0xe3e8f2)
    public static let dim = Color(hex: 0x9aa8c2)
    public static let faint = Color(hex: 0x6b7a96)

    public static let sun = Color(hex: 0xffcc33)
    public static let red = Color(hex: 0xff6b6b)
    public static let green = Color(hex: 0x7ee0a1)
    public static let blue = Color(hex: 0x6ea8ff)
    public static let magenta = Color(hex: 0xc792ea)
    public static let cyan = Color(hex: 0x5fd3e6)
    public static let orange = Color(hex: 0xffa657)

    /// Swatches offered for projects and new labels.
    public static let swatches: [String] = ["#ffcc33", "#ffa657", "#ff6b6b", "#c792ea", "#6ea8ff", "#5fd3e6", "#7ee0a1", "#98a2c4"]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }

    /// "#rrggbb" as stored on labels and projects; falls back to dim text.
    init(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        self = UInt32(s, radix: 16).flatMap { s.count == 6 ? Color(hex: $0) : nil } ?? Theme.dim
    }
}

extension Status {
    public var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .todo: return "circle"
        case .today: return "sun.max.fill"
        case .done: return "checkmark.circle.fill"
        case .canceled: return "xmark.circle"
        case .duplicate: return "equal.circle"
        }
    }
    public var tint: Color {
        switch self {
        case .inbox: return Theme.dim
        case .todo: return Theme.text
        case .today: return Theme.sun
        case .done: return Theme.green
        case .canceled, .duplicate: return Theme.faint
        }
    }
}

extension Priority {
    /// Bars like Linear's: more bars, more urgent; urgent is a filled square.
    public var symbol: String {
        switch self {
        case .none: return "minus"
        case .urgent: return "exclamationmark.square.fill"
        case .high, .medium, .low: return "cellularbars"
        }
    }
    public var level: Double? { [.high: 1.0, .medium: 0.66, .low: 0.33][self] }
    public var tint: Color {
        switch self {
        case .none: return Theme.faint
        case .urgent: return Theme.red
        case .high: return Theme.orange
        case .medium: return Theme.sun
        case .low: return Theme.blue
        }
    }
}

struct StatusGlyph: View {
    let status: Status
    var body: some View { Image(systemName: status.symbol).foregroundStyle(status.tint).frame(width: 16) }
}

struct PriorityGlyph: View {
    let priority: Int
    var body: some View {
        let p = Priority(rawValue: priority) ?? .none
        Group {
            if let v = p.level { Image(systemName: p.symbol, variableValue: v) } else { Image(systemName: p.symbol) }
        }
        .foregroundStyle(p.tint).frame(width: 16)
    }
}
