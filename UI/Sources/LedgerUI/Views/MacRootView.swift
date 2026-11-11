#if os(macOS)
import AppKit
import LedgerCore
import SwiftUI

public struct MacRootView: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var keys = KeyMonitor()

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            Content()
        }
        .inspector(isPresented: $model.detailOpen) {
            Group { if let id = model.selectedID { IssueDetailView(id: id) } else { EmptyState(text: "No issue selected") } }
                .inspectorColumnWidth(min: 340, ideal: 420, max: 620)
        }
        .overlay { if model.picker != nil { PickerOverlay() } }
        .overlay { if model.palette { PaletteView() } }
        .sheet(isPresented: $model.composing) { NewIssueView(status: model.composeStatus) }
        .confirmationDialog("Delete \(model.deleting?.identifier ?? "")?", isPresented: Binding { model.deleting != nil } set: { if !$0 { model.deleting = nil } }, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let i = model.deleting { model.delete(i) }; model.deleting = nil }
            Button("Cancel", role: .cancel) { model.deleting = nil }
        } message: { Text(model.deleting?.title ?? "") }
        .alert("Something went wrong", isPresented: Binding { model.error != nil } set: { if !$0 { model.error = nil } }) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .preferredColorScheme(.dark).tint(Theme.sun)
        .background(Theme.background)
        .toolbarBackground(Theme.bar, for: .windowToolbar)
        .onAppear {
            keys.install(model); model.start()
            // The search field would otherwise take focus at launch, which turns the single-key shortcuts off.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onChange(of: phase) { _, p in if p == .active { model.start() } }
    }
}

// MARK: keyboard

/// Linear's single-key shortcuts, active only while no text field has focus.
@MainActor final class KeyMonitor {
    private var token: Any?

    func install(_ model: LedgerModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.route(event, model) ? nil : event }
        }
    }

    static func route(_ e: NSEvent, _ model: LedgerModel) -> Bool {
        let responder = NSApp.keyWindow?.firstResponder
        let typing = responder is NSTextView
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if typing {
            guard e.keyCode == 53, !model.palette, !model.composing else { return false }
            NSApp.keyWindow?.makeFirstResponder(nil)
            if model.searchFocused { model.searchText = "" }
            return true
        }
        if mods == .command, e.keyCode == 51 { return model.handle(.delete) }
        if !mods.isEmpty { return false }
        switch e.keyCode {
        case 53: return model.handle(.escape)
        case 36, 76: return model.handle(.return)
        case 51, 117: return model.handle(.delete)
        case 126, 125:
            if responder is NSTableView || responder is NSOutlineView { return false }   // the sidebar keeps its own arrows
            return model.handle(e.keyCode == 126 ? .up : .down)
        default:
            guard let c = e.charactersIgnoringModifiers?.lowercased().first else { return false }
            return model.handle(.char(c))
        }
    }
}

public struct LedgerCommands: Commands {
    let model: LedgerModel
    public init(model: LedgerModel) { self.model = model }
    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Issue") { model.compose() }.keyboardShortcut("n")
        }
        CommandGroup(after: .textEditing) {
            Button("Command Palette") { model.palette = true }.keyboardShortcut("k")
            Button("Search") { model.searchFocus += 1 }.keyboardShortcut("f")
            Button("Sync Now") { Task { await model.syncNow() } }.keyboardShortcut("r")
            Button("Toggle Board") { model.layout = model.layout == .list ? .board : .list }.keyboardShortcut("b", modifiers: [.command, .shift])
        }
    }
}

// MARK: sidebar

private struct Sidebar: View {
    @Environment(LedgerModel.self) private var model
    @State private var newLabel = false
    @State private var labelName = ""

    var body: some View {
        List(selection: Binding<Scope?>(get: { model.scope }, set: { if let s = $0 { model.go(s) } })) {
            row("Inbox", "tray", .inbox, count: model.count(.inbox))
            row("Today", "sun.max", .today, count: model.count(.today))
            row("Current cycle", "arrow.triangle.2.circlepath", .cycle(nil))
            row("All issues", "list.bullet", .all)
            row("Projects", "folder", .projects)
            Section("Views") {
                ForEach(model.views) { v in
                    Label(v.name, systemImage: "line.3.horizontal.decrease.circle").tag(Scope.view(v.id))
                        .contextMenu { Button("Delete view", role: .destructive) { model.deleteView(v.id) } }
                }
            }
            Section {
                ForEach(model.labels) { l in
                    HStack(spacing: 8) { Circle().fill(Color(hexString: l.color)).frame(width: 8, height: 8); Text(l.name) }.tag(Scope.label(l.id))
                        .contextMenu { Button("Delete label", role: .destructive) { model.deleteLabel(l.id) } }
                }
            } header: {
                HStack { Text("Labels"); Spacer(); Button { labelName = ""; newLabel = true } label: { Image(systemName: "plus") }.buttonStyle(.plain) }
            }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden).background(Theme.bar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                if model.syncing { ProgressView().controlSize(.mini) }
                Text(model.syncLabel).lineLimit(1).font(.caption2).foregroundStyle(model.syncError == nil ? Theme.faint : Theme.red)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.bar).help(model.syncLabel)
        }
        .alert("New label", isPresented: $newLabel) {
            TextField("Name", text: $labelName)
            Button("Create") { model.createLabel(labelName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ name: String, _ icon: String, _ scope: Scope, count: Int = 0) -> some View {
        HStack {
            Label(name, systemImage: icon)
            Spacer()
            if count > 0 { Text("\(count)").font(.caption).foregroundStyle(Theme.faint) }
        }.tag(scope)
    }
}

// MARK: content

private struct Content: View {
    @Environment(LedgerModel.self) private var model
    @FocusState private var searchField: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.title).font(.headline)
                Text("\(model.visible.count)").foregroundStyle(Theme.faint)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField("Search", text: $model.searchText).textFieldStyle(.plain).focused($searchField).frame(width: 160)
                        .onChange(of: searchField) { _, f in model.searchFocused = f }
                }
                .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                if model.scope != .projects {
                    Picker("Layout", selection: $model.layout) {
                        Image(systemName: "list.bullet").tag(Layout.list); Image(systemName: "rectangle.split.3x1").tag(Layout.board)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 80)
                }
                Button { model.compose() } label: { Image(systemName: "plus") }.help("New issue (C)")
                Button { model.detailOpen.toggle() } label: { Image(systemName: "sidebar.right") }.help("Detail (Return)")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.dim)
            .padding(.horizontal, 12).frame(height: 44)
            Divider().overlay(Theme.line)
            switch model.scope {
            case .projects where !model.searching: ProjectsView()
            default:
                if case .cycle = model.scope, !model.searching { CycleHeader(cycle: model.cycle({ if case let .cycle(id) = model.scope { return id ?? model.currentCycleID } else { return nil } }())) }
                FilterBar()
                Divider().overlay(Theme.line)
                if model.layout == .board { BoardView() } else { IssueList() }
            }
        }
        .background(Theme.background)
        .onChange(of: model.searchFocus) { _, _ in searchField = true }
    }
}

private struct IssueList: View {
    @Environment(LedgerModel.self) private var model

    var body: some View {
        let groups = model.groups
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(groups) { g in
                        GroupHeader(group: g)
                        if !model.collapsed.contains(g.status) {
                            ForEach(g.issues) { i in
                                IssueRow(issue: i, selected: model.selectedID == i.id).id(i.id)
                                    .onTapGesture { model.select(i.id, open: true) }
                                    .contextMenu { IssueMenu(issue: i) }
                            }
                        }
                    }
                    if groups.isEmpty { EmptyState(text: model.searching ? "No matches" : "Nothing here") }
                }
            }
            .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }
}

struct IssueMenu: View {
    @Environment(LedgerModel.self) private var model
    let issue: Issue
    var body: some View {
        ForEach([PickerKind.status, .priority], id: \.self) { k in
            Menu(model.title(of: k)) { ForEach(model.options(k, for: issue)) { o in Button(o.title) { model.choose(o) } } }
        }
        Button("Open") { model.select(issue.id, open: true) }
        Divider()
        Button("Delete", role: .destructive) { model.deleting = issue }
    }
}

// MARK: board

private struct BoardView: View {
    @Environment(LedgerModel.self) private var model

    var body: some View {
        let groups = IssueGrouping.group(model.visible, keepEmpty: true)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(groups) { g in
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            StatusGlyph(status: g.status); Text(g.status.title).font(.subheadline.weight(.semibold))
                            Text("\(g.issues.count)").foregroundStyle(Theme.faint)
                            Spacer()
                            Button { model.compose(status: g.status) } label: { Image(systemName: "plus") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                        }
                        .padding(.horizontal, 6)
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(g.issues.prefix(g.status.isClosed ? 30 : 500)) { i in Card(issue: i) }
                                if g.status.isClosed, g.issues.count > 30 { Text("+\(g.issues.count - 30) more").font(.caption).foregroundStyle(Theme.faint) }
                            }
                        }
                    }
                    .frame(width: 270).padding(8)
                    .background(Theme.bar, in: RoundedRectangle(cornerRadius: 8))
                    .dropDestination(for: String.self) { ids, _ in
                        for id in ids { if let i = model.issue(id), i.status != g.status { model.setStatus(i, g.status) } }
                        return !ids.isEmpty
                    }
                }
            }
            .padding(12)
        }
    }

    private struct Card: View {
        @Environment(LedgerModel.self) private var model
        let issue: Issue
        var body: some View {
            let selected = model.selectedID == issue.id
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(issue.identifier).font(.caption.monospacedDigit()).foregroundStyle(Theme.faint)
                    Spacer()
                    PriorityGlyph(priority: issue.priority)
                }
                Text(issue.title).font(.callout).foregroundStyle(issue.status.isClosed ? Theme.dim : Theme.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    ForEach(issue.labels.compactMap { model.label($0) }.prefix(3)) { LabelChip(label: $0) }
                    Spacer()
                    if let d = issue.dueDate { Text(Format.due(d)).font(.caption).foregroundStyle(Format.isOverdue(issue) ? Theme.red : Theme.dim) }
                }
            }
            .padding(10)
            .background(selected ? Theme.raised : Theme.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.sun : Theme.line, lineWidth: selected ? 1.5 : 0.5))
            .onTapGesture { model.select(issue.id, open: true) }
            .draggable(issue.id)
            .contextMenu { IssueMenu(issue: issue) }
        }
    }
}

// MARK: overlays

/// The S / P / L / D picker: a short list with the key that chooses each row.
private struct PickerOverlay: View {
    @Environment(LedgerModel.self) private var model

    var body: some View {
        if let kind = model.picker, let issue = model.selected {
            ZStack(alignment: .top) {
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.picker = nil }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(model.title(of: kind)).font(.subheadline.weight(.semibold))
                        Text(model.shortcut(of: kind)).font(.caption2.monospaced()).padding(.horizontal, 4).background(Theme.field, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(Theme.dim)
                        Spacer()
                        Text(issue.identifier).font(.caption).foregroundStyle(Theme.faint)
                    }
                    .padding(10)
                    Divider().overlay(Theme.line)
                    let opts = model.options(kind, for: issue)
                    ForEach(Array(opts.enumerated()), id: \.element.id) { n, o in
                        HStack(spacing: 8) {
                            Group { if let s = o.symbol { if let l = o.level { Image(systemName: s, variableValue: l) } else { Image(systemName: s) } } }.foregroundStyle(o.tint).frame(width: 18)
                            Text(o.title)
                            Spacer()
                            if o.selected { Image(systemName: "checkmark").foregroundStyle(Theme.sun) }
                            if let h = o.hint { Text(h).font(.caption.monospaced()).foregroundStyle(Theme.faint) }
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(n == model.pickerIndex ? Theme.raised : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { model.choose(o) }
                    }
                }
                .frame(width: 280).background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                .padding(.top, 120)
            }
        }
    }
}

/// ⌘K: fuzzy jump to anything, and run actions.
private struct PaletteView: View {
    @Environment(LedgerModel.self) private var model
    @State private var query = ""
    @State private var index = 0
    @State private var items: [PaletteItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        let results = Palette.rank(items, query: query)
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.palette = false }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField("Jump to an issue, project, label or run a command", text: $query).textFieldStyle(.plain).font(.title3).focused($focused)
                        .onSubmit { run(results) }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
                        .onKeyPress(.escape) { model.palette = false; return .handled }
                }
                .padding(12)
                Divider().overlay(Theme.line)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { n, r in
                                HStack(spacing: 10) {
                                    Image(systemName: r.symbol).foregroundStyle(r.kind == .action ? Theme.sun : Theme.dim).frame(width: 18)
                                    Text(r.title).lineLimit(1)
                                    Spacer()
                                    Text(r.subtitle).font(.caption).foregroundStyle(Theme.faint)
                                }
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(n == index ? Theme.raised : Color.clear)
                                .contentShape(Rectangle()).id(r.id)
                                .onTapGesture { index = n; run(results) }
                            }
                            if results.isEmpty { Text("No matches").foregroundStyle(Theme.faint).padding(20) }
                        }
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: index) { _, n in if results.indices.contains(n) { proxy.scrollTo(results[n].id) } }
                }
            }
            .frame(width: 560).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .padding(.top, 90)
        }
        .onAppear { items = model.paletteItems(); focused = true }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(index) else { return }
        model.palette = false
        results[index].run()
    }
}
#endif
