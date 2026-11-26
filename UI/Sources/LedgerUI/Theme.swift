import LedgerCore
import SwiftUI

/// Vault: warm graphite and ivory, with gold leaf used sparingly, like engraving. Serif titles, monospaced figures,
/// tight corners. Meant to feel weighty and lasting: a bank, a church and a gym. Dark only.
public enum Theme {
    public static let background = Color(hex: 0x141210)   // content
    public static let bar = Color(hex: 0x0f0d0b)          // sidebar, bars, sheets
    public static let card = Color(hex: 0x1c1a17)         // cards, inputs
    public static let field = Color(hex: 0x221f1b)
    public static let raised = Color(hex: 0x2a2621)       // selected and hovered rows
    public static let line = Color(hex: 0x38322a)         // hairline rules

    public static let text = Color(hex: 0xede5d4)         // ivory
    public static let dim = Color(hex: 0xb7ad9a)
    public static let faint = Color(hex: 0x8c8371)

    public static let accent = Color(hex: 0xc9a55a)       // gold leaf: selection, progress, drop targets, Today
    public static let red = Color(hex: 0xd47c68)
    public static let green = Color(hex: 0x8fb68a)
    public static let blue = Color(hex: 0x90a8ca)
    public static let magenta = Color(hex: 0xb98ca9)
    public static let cyan = Color(hex: 0x80b1ad)
    public static let orange = Color(hex: 0xd39a5e)
    public static let yellow = Color(hex: 0xd6bf72)

    /// Swatches offered for projects and new labels.
    public static let swatches: [String] = ["#c9a55a", "#d39a5e", "#d47c68", "#b98ca9", "#90a8ca", "#80b1ad", "#8fb68a", "#d6bf72", "#b7ad9a"]

    public static let radius: CGFloat = 3

    /// Titles and column names: New York.
    public static func serif(_ style: Font.TextStyle) -> Font { .system(style, design: .serif).weight(.semibold) }
    /// Identifiers, counts and dates: SF Mono, like figures in a ledger.
    public static func mono(_ style: Font.TextStyle = .caption) -> Font { .system(style, design: .monospaced) }
}

extension View {
    /// Section labels: small letter-spaced capitals.
    func caps() -> some View { font(.caption2.weight(.semibold)).textCase(.uppercase).tracking(1.4).foregroundStyle(Theme.faint) }
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
        case .today: return Theme.accent
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
        case .medium: return Theme.yellow
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
