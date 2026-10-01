import SwiftUI
import UniformTypeIdentifiers
import BurnCore

struct ContentView: View {
    @StateObject private var model = BurnModel()
    // Plain @State is a macro in the current SDK, which Command Line Tools can't expand.
    @StateObject private var ui = ViewState()

    var body: some View {
        VStack(spacing: 0) {
            if model.toolsMissing { toolsBanner }
            header
            Divider()
            dropZone
            Divider()
            footer
            if ui.showLog { logView }
        }
        .frame(minWidth: 560, minHeight: 480)
        .task { await model.refreshAll() }
        .alert("Burn to disc?", isPresented: $ui.confirmBurn) {
            Button("Burn", role: .destructive) { Task { await model.burn() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        }
    }

    private var confirmMessage: String {
        let size = ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file)
        var s = "\(model.items.count) item(s), \(size), will be written as a new session. BD-R writes are permanent."
        if model.closeDisc { s += "\n\nThe disc will be CLOSED — no further sessions can be added." }
        return s
    }

    // MARK: - Sections

    private var toolsBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("cdrtools not found. Install with  `brew install cdrtools`  then relaunch.")
            Spacer()
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Drive", selection: $model.selectedDev) {
                    if model.drives.isEmpty { Text("No drive found").tag(String?.none) }
                    ForEach(model.drives) { d in Text(d.displayName).tag(Optional(d.dev)) }
                }
                .frame(maxWidth: 380)
                .onChange(of: model.selectedDev) { Task { await model.readMedia() } }
                Button {
                    Task { await model.refreshAll() }
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan drives and disc")
                .disabled(model.busy)
                Spacer()
                if model.busy && !model.isBurning { ProgressView().controlSize(.small) }
            }
            mediaStatus
        }
        .padding(12)
    }

    @ViewBuilder private var mediaStatus: some View {
        switch model.media {
        case .unknown:
            Text("Checking…").foregroundStyle(.secondary)
        case .noDrive:
            Label("No drive detected", systemImage: "opticaldiscdrive").foregroundStyle(.secondary)
        case .noDisc:
            Label("No disc inserted", systemImage: "opticaldisc").foregroundStyle(.secondary)
        case .mounted(let disk):
            HStack {
                Label("Disc is mounted by macOS (\(disk))", systemImage: "externaldrive")
                Button("Unmount & Read") { Task { await model.unmountAndRead() } }.disabled(model.busy)
            }
        case .error(let msg):
            Label(msg, systemImage: "xmark.octagon").foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
        case .ready(let m):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Label(m.mediaType.isEmpty ? "Disc" : m.mediaType, systemImage: "opticaldisc")
                    Text(statusText(m)).foregroundStyle(statusColor(m))
                    Spacer()
                    Text("\(bytes(m.remainingBytes)) free of \(bytes(m.capacityBytes))").foregroundStyle(.secondary)
                }
                CapacityBar(used: m.usedBytes, pending: model.totalSize, capacity: m.capacityBytes)
                    .frame(height: 8)
            }
        }
    }

    private func statusText(_ m: MediaInfo) -> String {
        switch m.diskStatus {
        case .empty: return "Blank"
        case .incomplete: return "Appendable · \(m.sessions) session\(m.sessions == 1 ? "" : "s")"
        case .complete: return "Closed · no more sessions"
        case .unknown: return "Unknown status"
        }
    }

    private func statusColor(_ m: MediaInfo) -> Color {
        m.isAppendable ? .green : .orange
    }

    private var dropZone: some View {
        ZStack {
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 40))
                    Text("Drop files and folders here").font(.title3)
                    Button("Add…") { openPanel() }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.items) { item in itemRow(item) }
                }
            }
            if ui.dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
            }
        }
        .frame(maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $ui.dropTargeted) { providers in
            guard !model.isBurning else { return false }
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add(urls: [url]) } }
                }
            }
            return true
        }
    }

    private func itemRow(_ item: BurnItem) -> some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            if item.hasHugeFile {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Contains a file over 4 GiB. It is written as a multi-extent ISO9660 file; macOS Finder may not read it correctly (Linux/Windows do).")
            }
            Spacer()
            if let s = item.size { Text(bytes(s)).foregroundStyle(.secondary).monospacedDigit() }
            else { ProgressView().controlSize(.small) }
            Button { model.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(model.isBurning)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Volume label", text: $model.volumeLabel)
                    .frame(maxWidth: 220)
                    .help("Up to 32 characters: letters, digits, space, _ and -")
                Toggle("Close disc after this session", isOn: $model.closeDisc)
                Toggle("Eject when done", isOn: $model.ejectWhenDone)
                Spacer()
            }
            .disabled(model.isBurning)

            if model.phase != .idle {
                VStack(alignment: .leading, spacing: 4) {
                    if model.isBurning { ProgressView(value: model.progress) }
                    Text(phaseText).font(.callout).foregroundStyle(phaseColor).lineLimit(3).textSelection(.enabled)
                }
            }

            HStack {
                Button("Add…") { openPanel() }.disabled(model.isBurning)
                Button("Clear") { model.items.removeAll() }.disabled(model.isBurning || model.items.isEmpty)
                Button(ui.showLog ? "Hide Log" : "Show Log") { ui.showLog.toggle() }
                Spacer()
                Text("\(model.items.count) item(s) · \(bytes(model.totalSize))").foregroundStyle(.secondary)
                if model.isBurning {
                    Button("Cancel", role: .destructive) { model.cancel() }
                } else {
                    Button("Burn") { ui.confirmBurn = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canBurn)
                }
            }
        }
        .padding(12)
    }

    private var phaseText: String {
        if case .failed(let msg) = model.phase { return "Failed: \(msg)" }
        return model.progressText
    }

    private var phaseColor: Color {
        switch model.phase {
        case .failed: return .red
        case .done: return .green
        default: return .primary
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("log")
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.log) { proxy.scrollTo("log", anchor: .bottom) }
        }
    }

    // MARK: - Helpers

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { model.add(urls: panel.urls) }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

final class ViewState: ObservableObject {
    @Published var dropTargeted = false
    @Published var confirmBurn = false
    @Published var showLog = false
}

struct CapacityBar: View {
    let used: Int64, pending: Int64, capacity: Int64

    var body: some View {
        GeometryReader { geo in
            let cap = Double(max(capacity, 1))
            let u = min(1, Double(used) / cap)
            let p = min(1 - u, Double(pending) / cap)
            let over = Double(used + pending) > cap
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                HStack(spacing: 0) {
                    Rectangle().fill(Color.secondary).frame(width: geo.size.width * u)
                    Rectangle().fill(over ? Color.red : Color.accentColor).frame(width: geo.size.width * p)
                }
                .clipShape(Capsule())
            }
        }
    }
}
