#if os(iOS)
import LedgerCore
import SwiftUI

public struct PhoneRootView: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    @State private var settings = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $tab) {
                page(.today).tabItem { SwiftUI.Label("Today", systemImage: "sun.max") }.tag(0)
                page(.inbox).tabItem { SwiftUI.Label("Inbox", systemImage: "tray") }.tag(1)
                page(.cycle(nil)).tabItem { SwiftUI.Label("Cycle", systemImage: "arrow.triangle.2.circlepath") }.tag(2)
                page(.all).tabItem { SwiftUI.Label("All", systemImage: "list.bullet") }.tag(3)
                page(.projects).tabItem { SwiftUI.Label("Projects", systemImage: "folder") }.tag(4)
            }
            if tab != 4 {
                Button { model.compose(status: tab == 0 ? .today : .inbox) } label: {
                    Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(Theme.bar)
                        .frame(width: 56, height: 56).background(Theme.sun, in: Circle())
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                }
                .padding(.trailing, 18).padding(.bottom, 66)
                .accessibilityLabel("New issue")
            }
        }
        .sheet(isPresented: $model.composing) { QuickAddSheet(status: model.composeStatus).presentationDetents([.height(220), .medium]) }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView().navigationTitle("Settings").navigationBarTitleDisplayMode(.inline) }.presentationDetents([.large]) }
        .alert("Something went wrong", isPresented: Binding { model.error != nil } set: { if !$0 { model.error = nil } }) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .preferredColorScheme(.dark).tint(Theme.sun)
        .onAppear { model.start() }
        .onChange(of: phase) { _, p in if p == .active { model.start() } else { model.stop() } }
        .environment(\.openSettings, { settings = true })
        .onChange(of: tab) { _, t in model.go([Scope.today, .inbox, .cycle(nil), .all, .projects][t]) }
    }

    private func page(_ s: Scope) -> some View {
        NavigationStack {
            PhonePage(scope: s)
                .navigationDestination(for: String.self) { IssueDetailView(id: $0).navigationBarTitleDisplayMode(.inline) }
        }
    }
}

private struct OpenSettingsKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues { var openSettings: () -> Void { get { self[OpenSettingsKey.self] } set { self[OpenSettingsKey.self] = newValue } } }

private struct PhonePage: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let scope: Scope
    @State private var search = ""

    var body: some View {
        Group {
            if scope == .projects { PhoneProjects() } else { PhoneList(scope: scope, search: search) }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { openSettings() } label: { Image(systemName: model.syncError == nil ? "gearshape" : "exclamationmark.triangle").foregroundStyle(model.syncError == nil ? Theme.dim : Theme.red) }
            }
        }
        .modifier(SearchIf(on: scope == .all, text: $search))
    }

    private var title: String {
        switch scope {
        case .cycle: return model.currentCycle.map { "Cycle \($0.number)" } ?? "Cycle"
        case .inbox: return "Inbox"
        case .today: return "Today"
        case .all: return "All issues"
        default: return "Projects"
        }
    }
}

private struct SearchIf: ViewModifier {
    let on: Bool
    @Binding var text: String
    func body(content: Content) -> some View { if on { content.searchable(text: $text, prompt: "Search issues") } else { content } }
}

private struct PhoneList: View {
    @Environment(LedgerModel.self) private var model
    let scope: Scope
    let search: String

    var body: some View {
        let issues = pick()
        let groups = IssueGrouping.group(issues)
        List {
            if case .cycle = scope { CycleHeader(cycle: model.currentCycle).listRowBackground(Theme.background).listRowSeparator(.hidden) }
            ForEach(groups) { g in
                Section {
                    if !model.collapsed.contains(g.status) {
                        ForEach(g.issues) { i in
                            NavigationLink(value: i.id) { IssueRow(issue: i, compact: true) }
                                .listRowBackground(Theme.background).listRowSeparatorTint(Theme.line)
                                .swipeActions(edge: .leading) {
                                    Button { model.setStatus(i, .done) } label: { SwiftUI.Label("Done", systemImage: "checkmark") }.tint(Theme.green)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { model.delete(i) } label: { SwiftUI.Label("Delete", systemImage: "trash") }
                                    Button { model.setStatus(i, .canceled) } label: { SwiftUI.Label("Cancel", systemImage: "xmark") }.tint(Theme.faint)
                                }
                        }
                    }
                } header: {
                    GroupHeader(group: g).listRowInsets(EdgeInsets())
                }
            }
            if groups.isEmpty { EmptyState(text: search.isEmpty ? "Nothing here" : "No matches").listRowBackground(Theme.background) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { await model.syncNow() }
    }

    private func pick() -> [Issue] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            var f = IssueFilter(); f.text = q
            return (try? model.ledger.issues(f)) ?? []
        }
        switch scope {
        case .inbox: return model.issues.filter { $0.status == .inbox }
        case .today: return model.issues.filter { $0.status == .today }
        case .cycle: return model.issues.filter { $0.cycleId == model.currentCycleID }
        default: return model.issues
        }
    }
}

private struct PhoneProjects: View {
    @Environment(LedgerModel.self) private var model
    @State private var editing: Project?
    @State private var creating = false

    var body: some View {
        List {
            ForEach(model.projects) { p in
                NavigationLink {
                    ProjectIssues(project: p)
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Color(hexString: p.color)).frame(width: 10, height: 10)
                        Text(p.name)
                        Spacer()
                        let c = model.projectCounts(p.id)
                        Text("\(c.open) open").font(.caption).foregroundStyle(Theme.dim)
                    }
                }
                .listRowBackground(Theme.background)
                .swipeActions { Button("Edit") { editing = p }.tint(Theme.blue) }
            }
            if model.projects.isEmpty { EmptyState(text: "No projects yet").listRowBackground(Theme.background) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button { creating = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $creating) { ProjectEditor(project: nil).presentationDetents([.medium]) }
        .sheet(item: $editing) { ProjectEditor(project: $0).presentationDetents([.medium]) }
    }
}

private struct ProjectIssues: View {
    @Environment(LedgerModel.self) private var model
    let project: Project
    var body: some View {
        let groups = IssueGrouping.group(model.issues.filter { $0.projectId == project.id })
        List {
            ForEach(groups) { g in
                Section {
                    if !model.collapsed.contains(g.status) {
                        ForEach(g.issues) { i in
                            NavigationLink(value: i.id) { IssueRow(issue: i, compact: true) }.listRowBackground(Theme.background)
                        }
                    }
                } header: { GroupHeader(group: g).listRowInsets(EdgeInsets()) }
            }
            if groups.isEmpty { EmptyState(text: "No issues in this project").listRowBackground(Theme.background) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(project.name)
    }
}
#endif
