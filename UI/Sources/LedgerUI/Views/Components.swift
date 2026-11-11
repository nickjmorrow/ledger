import LedgerCore
import SwiftUI

struct LabelChip: View {
    let label: LedgerCore.Label
    var body: some View {
        let c = Color(hexString: label.color)
        Text(label.name).font(.caption2).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(c).background(c.opacity(0.16), in: Capsule())
    }
}

struct IssueRow: View {
    @Environment(LedgerModel.self) private var model
    let issue: Issue
    var selected = false
    var compact = false

    var body: some View {
        let chips = issue.labels.compactMap { model.label($0) }
        let project = model.project(issue.projectId)
        let kids = model.children(of: issue.id)
        let overdue = Format.isOverdue(issue)
        let meta = HStack(spacing: 6) {
            ForEach(chips.prefix(3)) { LabelChip(label: $0) }
            if chips.count > 3 { Text("+\(chips.count - 3)").font(.caption2).foregroundStyle(Theme.faint) }
            if let project {
                HStack(spacing: 3) { Circle().fill(Color(hexString: project.color)).frame(width: 6, height: 6); Text(project.name).lineLimit(1) }
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            if !kids.isEmpty {
                HStack(spacing: 3) { Image(systemName: "arrow.turn.down.right"); Text("\(kids.filter { $0.status.isClosed }.count)/\(kids.count)") }
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            if let d = issue.dueDate {
                Text(Format.due(d)).font(.caption).foregroundStyle(overdue ? Theme.red : Theme.dim)
            }
            if issue.recur != nil { Image(systemName: "repeat").font(.caption2).foregroundStyle(Theme.faint) }
        }
        if compact {
            HStack(alignment: .top, spacing: 10) {
                StatusGlyph(status: issue.status).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title).foregroundStyle(issue.status.isClosed ? Theme.dim : Theme.text).lineLimit(2)
                    HStack(spacing: 6) {
                        PriorityGlyph(priority: issue.priority).font(.caption)
                        Text(issue.identifier).font(.caption.monospacedDigit()).foregroundStyle(Theme.faint)
                        meta
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                PriorityGlyph(priority: issue.priority)
                Text(issue.identifier).font(.caption.monospacedDigit()).foregroundStyle(Theme.faint).frame(width: 58, alignment: .leading)
                StatusGlyph(status: issue.status)
                Text(issue.title).foregroundStyle(issue.status.isClosed ? Theme.dim : Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                meta.layoutPriority(1)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(selected ? Theme.raised : Color.clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.sun).frame(width: 2) } }
            .contentShape(Rectangle())
        }
    }
}

/// The filter bar: a menu per property, "Save as view", and clear.
struct FilterBar: View {
    @Environment(LedgerModel.self) private var model
    @State private var naming = false
    @State private var viewName = ""

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            chip("Status", active: !model.filter.statuses.isEmpty) {
                ForEach(IssueGrouping.order, id: \.self) { s in
                    Toggle(isOn: toggle(\.statuses, s.rawValue)) { SwiftUI.Label(s.title, systemImage: s.symbol) }
                }
            }
            chip("Priority", active: !model.filter.priorities.isEmpty) {
                ForEach([1, 2, 3, 4, 0], id: \.self) { p in Toggle(Priority(rawValue: p)!.title, isOn: toggle(\.priorities, p)) }
            }
            chip("Label", active: !model.filter.labels.isEmpty) {
                if model.labels.isEmpty { Text("No labels yet") }
                ForEach(model.labels) { l in Toggle(l.name, isOn: toggle(\.labels, l.id)) }
            }
            chip("Project", active: model.filter.project != nil) {
                Button("Any project") { model.filter.project = nil }
                ForEach(model.projects) { p in Button { model.filter.project = p.id } label: { Text(model.filter.project == p.id ? "✓ \(p.name)" : p.name) } }
            }
            chip("Due", active: model.filter.due != nil) {
                Button("Any time") { model.filter.due = nil }
                ForEach(DueFilter.allCases, id: \.self) { d in Button { model.filter.due = d } label: { Text(model.filter.due == d ? "✓ \(d.title)" : d.title) } }
            }
            if !model.filter.isEmpty {
                Button("Clear") { model.filter = ViewFilter() }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.dim)
            }
            Spacer()
            if case let .view(id) = model.scope {
                if model.viewChanged { Button("Update view") { model.updateView(id) }.font(.caption).buttonStyle(.borderless) }
            } else if !model.filter.isEmpty {
                Button("Save as view") { viewName = ""; naming = true }.font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .alert("Save as view", isPresented: $naming) {
            TextField("Name", text: $viewName)
            Button("Save") { if !viewName.trimmingCharacters(in: .whitespaces).isEmpty { model.saveView(name: viewName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func toggle<T: Hashable>(_ kp: WritableKeyPath<ViewFilter, [T]>, _ v: T) -> Binding<Bool> {
        Binding { model.filter[keyPath: kp].contains(v) } set: { on in
            if on { model.filter[keyPath: kp].append(v) } else { model.filter[keyPath: kp].removeAll { $0 == v } }
        }
    }

    private func chip<C: View>(_ name: String, active: Bool, @ViewBuilder _ content: () -> C) -> some View {
        Menu { content() } label: {
            Text(name).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(active ? Theme.bar : Theme.dim)
                .background(active ? Theme.sun : Theme.field, in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A group's header: collapse chevron, status, count, and a + to add into that status.
struct GroupHeader: View {
    @Environment(LedgerModel.self) private var model
    let group: IssueGrouping.Group
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.collapsed.contains(group.status) ? "chevron.right" : "chevron.down").font(.caption2).foregroundStyle(Theme.faint).frame(width: 12)
            StatusGlyph(status: group.status)
            Text(group.status.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            Text("\(group.issues.count)").font(.subheadline).foregroundStyle(Theme.faint)
            Spacer()
            #if os(macOS)
            Button { model.compose(status: group.status) } label: { Image(systemName: "plus") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
            #endif
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(Theme.bar)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleCollapsed(group.status) }
    }
}

struct EmptyState: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, minHeight: 160) }
}

/// The cycle page's header: dates, days left and progress.
struct CycleHeader: View {
    @Environment(LedgerModel.self) private var model
    let cycle: Cycle?
    var body: some View {
        if let cycle {
            let mine = model.issues.filter { $0.cycleId == cycle.id && $0.status != .canceled && $0.status != .duplicate }
            let done = mine.filter { $0.status == .done }.count
            let left = Ledger.date(fromDay: cycle.endsAt).flatMap { Calendar.current.dateComponents([.day], from: Ledger.date(fromDay: Ledger.day())!, to: $0).day } ?? 0
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cycle \(cycle.number)").font(.headline)
                    Text(Format.range(cycle)).foregroundStyle(Theme.dim)
                    Spacer()
                    Text(left > 0 ? "\(left) days left" : "ended").font(.subheadline).foregroundStyle(Theme.dim)
                }
                ProgressView(value: Double(done), total: Double(max(mine.count, 1))).tint(Theme.sun)
                Text("\(done) of \(mine.count) done").font(.caption).foregroundStyle(Theme.dim)
            }
            .padding(12)
        }
    }
}
