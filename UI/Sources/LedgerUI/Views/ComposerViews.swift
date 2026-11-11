import LedgerCore
import SwiftUI

/// New issue: title first (shorthand `due:tomorrow p:high #label` works), optional notes, a few properties. ⌘Return saves.
struct NewIssueView: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var status: Status
    @State private var priority = 0
    @State private var projectID: String?
    @State private var labelIDs: [String] = []
    @State private var due: String?
    @FocusState private var focused: Bool

    init(status: Status) { _status = State(initialValue: status) }

    var body: some View {
        let q = QuickAdd.parse(title, labels: model.labels)
        VStack(alignment: .leading, spacing: 12) {
            Text("New issue").font(.headline)
            TextField("Issue title", text: $title).textFieldStyle(.plain).font(.title3)
                .focused($focused).onSubmit(save)
            if q.due != nil || q.priority != nil || !q.labelIds.isEmpty {
                HStack(spacing: 6) {
                    if let p = q.priority { chip(Priority(rawValue: p)?.title ?? "") }
                    if let d = q.due { chip(Format.due(d)) }
                    ForEach(q.labelIds, id: \.self) { id in if let l = model.label(id) { LabelChip(label: l) } }
                }
            }
            TextField("Add notes (Markdown)", text: $notes, axis: .vertical).textFieldStyle(.plain).lineLimit(3...8).foregroundStyle(Theme.dim)
            HStack(spacing: 8) {
                Menu {
                    ForEach(Status.allCases, id: \.self) { s in Button { status = s } label: { Text(s.title) } }
                } label: { HStack(spacing: 4) { StatusGlyph(status: status); Text(status.title) } }
                Menu {
                    ForEach([1, 2, 3, 4, 0], id: \.self) { p in Button(Priority(rawValue: p)!.title) { priority = p } }
                } label: { HStack(spacing: 4) { PriorityGlyph(priority: priority); Text(Priority(rawValue: priority)!.title) } }
                Menu {
                    Button("No project") { projectID = nil }
                    ForEach(model.projects) { p in Button(p.name) { projectID = p.id } }
                } label: { Text(model.project(projectID)?.name ?? "Project") }
                Menu {
                    ForEach(model.labels) { l in Toggle(l.name, isOn: Binding { labelIDs.contains(l.id) } set: { on in if on { labelIDs.append(l.id) } else { labelIDs.removeAll { $0 == l.id } } }) }
                } label: { Text(labelIDs.isEmpty ? "Labels" : "\(labelIDs.count) labels") }
                Menu {
                    ForEach([("Today", 0), ("Tomorrow", 1), ("In a week", 7)], id: \.1) { n, d in
                        Button(n) { due = Ledger.day(Calendar.current.date(byAdding: .day, value: d, to: Date())!) }
                    }
                    Button("No due date") { due = nil }
                } label: { Text(due.map { Format.due($0) } ?? "Due") }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).font(.callout).foregroundStyle(Theme.dim)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create issue") { save() }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(q.title.isEmpty && title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: 560)
        #endif
        .background(Theme.bar)
        .onAppear { focused = true }
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).foregroundStyle(Theme.sun).background(Theme.sun.opacity(0.16), in: Capsule())
    }

    private func save() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var extra: [String: SyncValue] = [:]
        if priority != 0 { extra["priority"] = .int(Int64(priority)) }
        if let due { extra["dueDate"] = .text(due) }
        if !labelIDs.isEmpty { extra["labels"] = .text(String(decoding: (try? JSONEncoder().encode(labelIDs)) ?? Data("[]".utf8), as: UTF8.self)) }
        if let i = model.quickCreate(title, status: status, notes: notes, projectID: projectID, extra: extra) { model.select(i.id) }
        dismiss()
    }
}

/// The iPhone's quick add: just a title (shorthand works), status Inbox, one thumb.
struct QuickAddSheet: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var focused: Bool
    var status: Status = .inbox

    var body: some View {
        let q = QuickAdd.parse(title, labels: model.labels)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("New issue").font(.headline)
                Spacer()
                Button("Add") { add() }.fontWeight(.semibold).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("Title   (due:tomorrow  p:high  #label)", text: $title).focused($focused).onSubmit(add)
                .textFieldStyle(.plain).font(.title3).submitLabel(.done)
            HStack(spacing: 6) {
                if let p = q.priority { Text(Priority(rawValue: p)?.title ?? "") }
                if let d = q.due { Text(Format.due(d)) }
                ForEach(q.labelIds, id: \.self) { id in if let l = model.label(id) { LabelChip(label: l) } }
            }
            .font(.caption).foregroundStyle(Theme.sun)
            Spacer(minLength: 0)
        }
        .padding(16).background(Theme.bar)
        .onAppear { focused = true }
    }

    private func add() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.quickCreate(title, status: status)
        dismiss()
    }
}

struct ProjectEditor: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project?
    @State private var name = ""
    @State private var color = Theme.swatches[0]
    @State private var notes = ""
    @State private var status = "active"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(project == nil ? "New project" : "Edit project").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Description", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            HStack {
                ForEach(Theme.swatches, id: \.self) { c in
                    Circle().fill(Color(hexString: c)).frame(width: 20, height: 20)
                        .overlay { if c == color { Circle().stroke(Theme.text, lineWidth: 2).padding(-3) } }
                        .onTapGesture { color = c }
                }
            }
            Picker("Status", selection: $status) { ForEach(["active", "paused", "completed"], id: \.self) { Text($0.capitalized).tag($0) } }
            HStack {
                if let project { Button("Delete", role: .destructive) { model.deleteProject(project.id); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveProject(id: project?.id, name: name.trimmingCharacters(in: .whitespaces), color: color, description: notes, status: status)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(minWidth: 320).background(Theme.bar)
        .onAppear {
            if let project { name = project.name; color = project.color; notes = project.description; status = project.status }
        }
    }
}

/// The Projects page: every project with its open and total issues; tapping one lists its issues.
struct ProjectsView: View {
    @Environment(LedgerModel.self) private var model
    @State private var editing: Project?
    @State private var creating = false

    var body: some View {
        List {
            ForEach(model.projects) { p in
                let c = model.projectCounts(p.id)
                Button { model.go(.project(p.id)) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Color(hexString: p.color)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundStyle(Theme.text)
                            if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(Theme.dim).lineLimit(1) }
                        }
                        Spacer()
                        if p.status != "active" { Text(p.status.capitalized).font(.caption).foregroundStyle(Theme.faint) }
                        Text("\(c.open) open / \(c.total)").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Edit") { editing = p }; Button("Delete", role: .destructive) { model.deleteProject(p.id) } }
                .swipeActions { Button("Edit") { editing = p }.tint(Theme.blue) }
                .listRowBackground(Theme.background)
            }
            if model.projects.isEmpty { EmptyState(text: "No projects yet").listRowBackground(Theme.background) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
        .toolbar { ToolbarItem { Button { creating = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $creating) { ProjectEditor(project: nil) }
        .sheet(item: $editing) { ProjectEditor(project: $0) }
    }
}

public struct SettingsView: View {
    @Environment(LedgerModel.self) private var model
    @State private var url = ""
    @State private var token = ""
    @State private var host = ""

    public init() {}

    public var body: some View {
        Form {
            Section("Sync") {
                TextField("Hub URL", text: $url, prompt: Text("http://hub-host:8455"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                SecureField("Token", text: $token)
                TextField("Host header (only when connecting by IP)", text: $host)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                HStack {
                    Button("Save") { model.saveSettings(SyncSettings(url: url, token: token, hostHeader: host)) }
                        .disabled(!SyncSettings(url: url, token: token, hostHeader: host).isValid)
                    if model.syncConfigured && model.settings != nil { Button("Reset to defaults") { model.clearSettings(); load() } }
                }
            }
            Section("Status") {
                LabeledContent("Last sync", value: model.lastSync.map { Format.ago($0) } ?? "never")
                if let e = model.syncError { Text(e).foregroundStyle(Theme.red) }
                Button { Task { await model.syncNow() } } label: { model.syncing ? AnyView(ProgressView()) : AnyView(Text("Sync now")) }
                    .disabled(model.syncing || !model.syncConfigured)
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).background(Theme.bar)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .onAppear(perform: load)
    }

    private func load() {
        url = model.settings?.url ?? ""; token = model.settings?.token ?? ""; host = model.settings?.hostHeader ?? ""
    }
}
