import LedgerCore
import SwiftUI

/// Saves a text edit shortly after typing stops, and when the view goes away, so each keystroke isn't a database write.
struct Autosave: ViewModifier {
    let text: String
    let original: String
    let save: (String) -> Void
    func body(content: Content) -> some View {
        content
            .task(id: text) {
                guard text != original else { return }
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { save(text) }
            }
            .onDisappear { if text != original { save(text) } }
    }
}

/// Everything about one issue: editable title, Markdown description, property pickers and sub-issues. Shared by the Mac inspector
/// and the iPhone's pushed screen.
public struct IssueDetailView: View {
    @Environment(LedgerModel.self) private var model
    let id: String

    public init(id: String) { self.id = id }

    public var body: some View {
        if let issue = model.issue(id) {
            DetailBody(issue: issue).id(issue.id)
        } else {
            EmptyState(text: "Issue not found")
        }
    }
}

private struct DetailBody: View {
    @Environment(LedgerModel.self) private var model
    let issue: Issue
    @State private var title: String
    @State private var notes: String
    @State private var preview = false
    @State private var newChild = ""
    @State private var dueOpen = false
    @State private var parentOpen = false

    init(issue: Issue) {
        self.issue = issue
        _title = State(initialValue: issue.title)
        _notes = State(initialValue: issue.description)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(issue.identifier).font(.caption.monospacedDigit()).foregroundStyle(Theme.faint)
                    Spacer()
                    Text("Created \(String(issue.createdAt.prefix(10)))").font(.caption).foregroundStyle(Theme.faint)
                }
                TextField("Title", text: $title, axis: .vertical)
                    .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                    .modifier(Autosave(text: title, original: issue.title) { t in
                        let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { model.edit(issue.id, ["title": .text(clean)]) }
                    })

                properties
                Divider().overlay(Theme.line)
                description
                Divider().overlay(Theme.line)
                subIssues
            }
            .padding(16)
        }
        .background(Theme.bar)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: properties

    private var properties: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Status", hint: "S") { menu(.status) { Text(issue.status.title) } icon: { StatusGlyph(status: issue.status) } }
            row("Priority", hint: "P") { menu(.priority) { Text((Priority(rawValue: issue.priority) ?? .none).title) } icon: { PriorityGlyph(priority: issue.priority) } }
            row("Labels", hint: "L") { labelsMenu }
            row("Project") { projectMenu }
            row("Cycle") { cycleMenu }
            row("Due", hint: "D") { dueButton }
            row("Parent") { parentButton }
            row("Repeat") { recurrence }
        }
    }

    private func row<C: View>(_ name: String, hint: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(name).foregroundStyle(Theme.dim)
                #if os(macOS)
                if let hint { Text(hint).font(.caption2.monospaced()).foregroundStyle(Theme.faint).padding(.horizontal, 4).background(Theme.field, in: RoundedRectangle(cornerRadius: 3)) }
                #endif
            }
            .frame(width: 96, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .font(.callout).frame(minHeight: 30)
    }

    private func menu<T: View, I: View>(_ kind: PickerKind, @ViewBuilder _ label: () -> T, @ViewBuilder icon: () -> I) -> some View {
        Menu {
            ForEach(model.options(kind, for: issue)) { o in
                Button { model.choose(o) } label: {
                    Text("\(o.selected ? "✓ " : "")\(o.title)\(o.hint.map { "    \($0)" } ?? "")")
                }
            }
        } label: { HStack(spacing: 6) { icon(); label() }.foregroundStyle(Theme.text) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var labelsMenu: some View {
        let mine = issue.labels.compactMap { model.label($0) }
        return Menu {
            if model.labels.isEmpty { Text("No labels yet") }
            ForEach(model.labels) { l in
                Toggle(l.name, isOn: Binding { issue.labels.contains(l.id) } set: { _ in model.toggleLabel(issue, l.id) })
            }
        } label: {
            if mine.isEmpty { Text("None").foregroundStyle(Theme.faint) }
            else { HStack(spacing: 4) { ForEach(mine) { LabelChip(label: $0) } } }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var projectMenu: some View {
        Menu {
            Button("No project") { model.setProject(issue, nil) }
            ForEach(model.projects) { p in Button("\(issue.projectId == p.id ? "✓ " : "")\(p.name)") { model.setProject(issue, p.id) } }
        } label: {
            if let p = model.project(issue.projectId) {
                HStack(spacing: 4) { Circle().fill(Color(hexString: p.color)).frame(width: 8, height: 8); Text(p.name).foregroundStyle(Theme.text) }
            } else { Text("None").foregroundStyle(Theme.faint) }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var cycleMenu: some View {
        Menu {
            Button("No cycle") { model.setCycle(issue, nil) }
            ForEach(model.cycles.prefix(8)) { c in
                Button("\(issue.cycleId == c.id ? "✓ " : "")Cycle \(c.number)  \(Format.range(c))\(c.id == model.currentCycleID ? "  (current)" : "")") { model.setCycle(issue, c.id) }
            }
        } label: {
            if let c = model.cycle(issue.cycleId) { Text("Cycle \(c.number)").foregroundStyle(Theme.text) } else { Text("None").foregroundStyle(Theme.faint) }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var dueButton: some View {
        Button { dueOpen = true } label: {
            if let d = issue.dueDate { Text(Format.due(d)).foregroundStyle(Format.isOverdue(issue) ? Theme.red : Theme.text) }
            else { Text("None").foregroundStyle(Theme.faint) }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $dueOpen) { DuePopover(issue: issue, close: { dueOpen = false }) }
    }

    private var parentButton: some View {
        Button { parentOpen = true } label: {
            if let p = model.issue(issue.parentId) { Text("\(p.identifier) \(p.title)").lineLimit(1).foregroundStyle(Theme.text) }
            else { Text("None").foregroundStyle(Theme.faint) }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $parentOpen) { ParentPopover(issue: issue, close: { parentOpen = false }) }
    }

    private var recurrence: some View {
        let r = issue.recurrence
        return HStack(spacing: 8) {
            Menu {
                Button("Does not repeat") { model.setRecurrence(issue, nil) }
                ForEach([("Daily", Recurrence.Unit.day), ("Weekly", .week), ("Monthly", .month)], id: \.1) { name, unit in
                    Button("\(r?.every == unit ? "✓ " : "")\(name)") { model.setRecurrence(issue, Recurrence(every: unit, interval: r?.interval ?? 1)) }
                }
            } label: {
                Text(r.map { "Every \($0.interval == 1 ? "" : "\($0.interval) ")\($0.every.rawValue)\($0.interval == 1 ? "" : "s")" } ?? "None")
                    .foregroundStyle(r == nil ? Theme.faint : Theme.text)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            if let r {
                Stepper("", value: Binding { r.interval } set: { model.setRecurrence(issue, Recurrence(every: r.every, interval: max($0, 1))) }, in: 1...30).labelsHidden()
            }
        }
    }

    // MARK: description and sub-issues

    private var description: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Description").font(.callout).foregroundStyle(Theme.dim)
                Spacer()
                Picker("", selection: $preview) { Text("Edit").tag(false); Text("Preview").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            if preview {
                MarkdownPreview(text: notes).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden).font(.body.monospaced())
                    .frame(minHeight: 140)
                    .padding(6).background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                    .modifier(Autosave(text: notes, original: issue.description) { model.edit(issue.id, ["description": .text($0)]) })
            }
        }
    }

    private var subIssues: some View {
        let kids = model.children(of: issue.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Sub-issues\(kids.isEmpty ? "" : "  \(kids.filter { $0.status.isClosed }.count)/\(kids.count)")").font(.callout).foregroundStyle(Theme.dim)
            ForEach(kids) { k in
                HStack(spacing: 8) {
                    Button { model.setStatus(k, k.status == .done ? .todo : .done) } label: { StatusGlyph(status: k.status) }.buttonStyle(.plain)
                    Text(k.identifier).font(.caption.monospacedDigit()).foregroundStyle(Theme.faint)
                    Text(k.title).lineLimit(1).foregroundStyle(k.status.isClosed ? Theme.dim : Theme.text)
                    Spacer()
                }
                .frame(minHeight: 28).contentShape(Rectangle())
                .onTapGesture { model.select(k.id, open: true) }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(Theme.faint).frame(width: 16)
                TextField("Add sub-issue", text: $newChild).textFieldStyle(.plain)
                    .onSubmit {
                        let t = newChild.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        model.quickCreate(t, status: .todo, parentID: issue.id, extra: issue.projectId.map { ["projectId": .text($0)] } ?? [:])
                        newChild = ""
                    }
            }
            .frame(minHeight: 28)
        }
    }
}

struct DuePopover: View {
    @Environment(LedgerModel.self) private var model
    let issue: Issue
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.options(.due, for: issue)) { o in
                Button { model.choose(o); close() } label: { Text(o.title).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
            }
            Divider()
            DatePicker("", selection: Binding {
                issue.dueDate.flatMap { Ledger.date(fromDay: $0) } ?? Date()
            } set: { model.setDue(issue, Ledger.day($0)) }, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
        }
        .padding(12).frame(width: 280).presentationCompactAdaptation(.popover)
    }
}

struct ParentPopover: View {
    @Environment(LedgerModel.self) private var model
    let issue: Issue
    let close: () -> Void
    @State private var query = ""
    var body: some View {
        let hits: [Issue] = {
            let all = model.issues.filter { $0.id != issue.id && $0.parentId != issue.id }
            let q = query.trimmingCharacters(in: .whitespaces)
            let ranked = q.isEmpty ? all.filter { !$0.status.isClosed }.sorted { ($0.number ?? 0) > ($1.number ?? 0) } : all.compactMap { i in
                (Fuzzy.score(q.replacingOccurrences(of: "mor-", with: "", options: .caseInsensitive), in: "\(i.number ?? 0) \(i.title)")).map { (i, $0) }
            }.sorted { $0.1 > $1.1 }.map(\.0)
            return Array(ranked.prefix(12))
        }()
        VStack(alignment: .leading, spacing: 6) {
            TextField("Parent issue", text: $query).textFieldStyle(.roundedBorder)
            if issue.parentId != nil { Button("Remove parent") { model.setParent(issue, nil); close() }.buttonStyle(.plain).foregroundStyle(Theme.red) }
            ForEach(hits) { i in
                Button { model.setParent(issue, i.id); close() } label: {
                    Text("\(i.identifier)  \(i.title)").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
        .padding(12).frame(width: 320).presentationCompactAdaptation(.popover)
    }
}

/// Markdown as written: headings, bullets and checkboxes by line, bold, italic, code and links inside lines (AttributedString).
struct MarkdownPreview: View {
    let text: String
    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Nothing to preview").foregroundStyle(Theme.faint)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in render(line) }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func render(_ line: String) -> some View {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let h = t.range(of: #"^#{1,6} "#, options: .regularExpression) {
            let level = t.distance(from: t.startIndex, to: h.upperBound) - 1
            inline(String(t[h.upperBound...])).font(level == 1 ? .title3.bold() : .headline)
        } else if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") {
            HStack(alignment: .top, spacing: 6) { Image(systemName: t.hasPrefix("- [x]") ? "checkmark.square.fill" : "square").foregroundStyle(Theme.dim); inline(String(t.dropFirst(6))) }
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) { Text("•").foregroundStyle(Theme.dim); inline(String(t.dropFirst(2))) }
        } else if t.isEmpty {
            Spacer().frame(height: 4)
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a)
    }
}
