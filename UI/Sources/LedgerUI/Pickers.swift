import Foundation
import LedgerCore
import SwiftUI

public struct PickerOption: Identifiable {
    public var id: String
    public var title: String
    public var symbol: String?
    public var level: Double?
    public var tint: Color = Theme.text
    public var selected = false
    /// The key that chooses it while the picker is open.
    public var hint: String?
    /// A toggle (labels) stays open after choosing.
    public var keepsOpen = false
    public var run: @MainActor () -> Void
}

/// The choices behind a property: used by the detail's menus, the S/P/L/D pickers, context menus and the command palette.
extension LedgerModel {
    public func title(of kind: PickerKind) -> String { ["status": "Status", "priority": "Priority", "label": "Labels", "due": "Due date"][kind.rawValue]! }
    public func shortcut(of kind: PickerKind) -> String { ["status": "S", "priority": "P", "label": "L", "due": "D"][kind.rawValue]! }

    public func options(_ kind: PickerKind, for i: Issue) -> [PickerOption] {
        switch kind {
        case .status:
            return Status.allCases.enumerated().map { n, s in
                PickerOption(id: s.rawValue, title: s.title, symbol: s.symbol, tint: s.tint, selected: i.status == s, hint: "\(n + 1)") { self.setStatus(i, s) }
            }
        case .priority:
            return ([1, 2, 3, 4, 0]).map { p in
                let pr = Priority(rawValue: p)!
                return PickerOption(id: "p\(p)", title: pr.title, symbol: pr.symbol, level: pr.level, tint: pr.tint, selected: i.priority == p, hint: "\(p)") { self.setPriority(i, p) }
            }
        case .label:
            return labels.enumerated().map { n, l in
                PickerOption(id: l.id, title: l.name, symbol: "circle.fill", tint: Color(hexString: l.color), selected: i.labels.contains(l.id), hint: n < 9 ? "\(n + 1)" : nil, keepsOpen: true) { self.toggleLabel(i, l.id) }
            }
        case .due:
            let cal = Calendar.current, now = Date()
            func day(_ n: Int) -> String { Ledger.day(cal.date(byAdding: .day, value: n, to: now)!) }
            let monday = QuickAdd.date("nextweek", today: now)!
            let choices: [(String, String?)] = [("Today", day(0)), ("Tomorrow", day(1)), ("Next Monday", monday), ("In two weeks", day(14)), ("No due date", nil)]
            return choices.enumerated().map { n, c in
                PickerOption(id: "due\(n)", title: c.0, symbol: c.1 == nil ? "calendar.badge.minus" : "calendar", selected: i.dueDate == c.1, hint: "\(n + 1)") { self.setDue(i, c.1) }
            }
        }
    }

    public func choose(_ o: PickerOption) {
        o.run()
        if !o.keepsOpen { picker = nil }
    }

    // MARK: keys

    public enum Key: Equatable { case char(Character), up, down, `return`, escape, delete }

    /// Linear's keys. Called only when no text field has focus. True when the key was used.
    @discardableResult
    public func handle(_ key: Key) -> Bool {
        if palette || composing || deleting != nil { return false }
        if let kind = picker, let i = selected {
            let opts = options(kind, for: i)
            switch key {
            case .escape: picker = nil
            case .up, .char("k"): pickerIndex = max(pickerIndex - 1, 0)
            case .down, .char("j"): pickerIndex = min(pickerIndex + 1, max(opts.count - 1, 0))
            case .return, .char(" "): if opts.indices.contains(pickerIndex) { choose(opts[pickerIndex]) }
            case let .char(c):
                if let o = opts.first(where: { $0.hint == String(c) }) { choose(o) }
            default: break
            }
            return true
        }
        switch key {
        case .char("c"): compose()
        case .char("j"), .down: move(1)
        case .char("k"), .up: move(-1)
        case .return: if selectedID != nil { detailOpen = true }
        case .escape:
            if detailOpen { detailOpen = false } else if selectedID != nil { selectedID = nil }
            else if !filter.isEmpty { filter = ViewFilter() } else if searching { searchText = "" } else { return false }
        case .char("s"): open(.status)
        case .char("p"): open(.priority)
        case .char("l"): open(.label)
        case .char("d"): open(.due)
        case .char("/"): searchFocus += 1
        case .delete: if let i = selected { deleting = i } else { return false }
        default: return false
        }
        return true
    }

    public func open(_ kind: PickerKind) {
        guard let i = selected else { return }
        pickerIndex = options(kind, for: i).firstIndex { $0.selected } ?? 0
        picker = kind
    }

    // MARK: command palette

    public func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ id: String, _ kind: PaletteItem.Kind, _ title: String, _ sub: String = "", _ symbol: String, number: Int? = nil, _ run: @escaping @MainActor () -> Void) {
            items.append(PaletteItem(id: id, kind: kind, title: title, subtitle: sub, symbol: symbol, number: number, run: run))
        }
        add("new", .action, "Create issue", "C", "plus") { self.compose() }
        add("go-inbox", .action, "Go to Inbox", "", "tray") { self.go(.inbox) }
        add("go-today", .action, "Go to Today", "", "sun.max") { self.go(.today) }
        add("go-cycle", .action, "Go to Current cycle", "", "arrow.triangle.2.circlepath") { self.go(.cycle(nil)) }
        add("go-all", .action, "Go to All issues", "", "list.bullet") { self.go(.all) }
        add("go-projects", .action, "Go to Projects", "", "folder") { self.go(.projects) }
        add("layout", .action, layout == .list ? "Show as board" : "Show as list", "", layout == .list ? "rectangle.split.3x1" : "list.bullet") { self.layout = self.layout == .list ? .board : .list }
        add("sync", .action, "Sync now", "", "arrow.clockwise") { Task { await self.syncNow() } }
        if let i = selected {
            for k in PickerKind.allCases {
                for o in options(k, for: i) {
                    add("set-\(k.rawValue)-\(o.id)", .action, "\(title(of: k)): \(o.title)", i.identifier, o.symbol ?? "circle") { o.run() }
                }
            }
            add("delete", .action, "Delete \(i.identifier)", "⌘⌫", "trash") { self.deleting = i }
        }
        for i in issues.sorted(by: { ($0.number ?? .max) > ($1.number ?? .max) }) {
            add("i-\(i.id)", .issue, i.title, i.identifier, i.status.symbol, number: i.number) { self.reveal(i) }
        }
        for p in projects { add("p-\(p.id)", .project, p.name, "Project", "folder") { self.go(.project(p.id)) } }
        for l in labels { add("l-\(l.id)", .label, l.name, "Label", "tag") { self.go(.label(l.id)) } }
        for v in views { add("v-\(v.id)", .view, v.name, "View", "line.3.horizontal.decrease.circle") { self.go(.view(v.id)) } }
        for c in cycles { add("c-\(c.id)", .cycle, "Cycle \(c.number)", Format.range(c), "arrow.triangle.2.circlepath") { self.go(.cycle(c.id)) } }
        return items
    }

    /// Jumps to an issue: shows it in the list that can show it, selects it and opens the detail.
    public func reveal(_ i: Issue) {
        if !visible.contains(where: { $0.id == i.id }) { go(.all) }
        collapsed.remove(i.status)
        select(i.id, open: true)
    }
}
