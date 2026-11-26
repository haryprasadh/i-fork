import SwiftUI
import AppKit

/// Bottom bar: one row per running transfer (max 3), each with the files copying right now.
/// When nothing is running, shows the last finished transfer until dismissed.
struct TransferBar: View {
    private let center = TransferCenter.shared
    private let ui = UIState.shared

    var body: some View {
        let active = center.active
        let shown: [TransferJob] = active.isEmpty
            ? center.jobs.prefix(1).filter { $0.id != ui.dismissedJob }
            : Array(active.prefix(3))
        if !shown.isEmpty {
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 10) {
                    ForEach(shown) { job in
                        JobRow(job: job)
                        if job.id != shown.last?.id { Divider() }
                    }
                    if active.count > 3 {
                        Text("+\(active.count - 3) more transfers running").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(.bar)
        }
    }
}

private struct JobRow: View {
    let job: TransferJob
    private let center = TransferCenter.shared
    private let ui = UIState.shared

    private var expanded: Bool { ui.expandedJobs.contains(job.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                statusIcon
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(job.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if job.isActive {
                        ProgressView(value: job.progress).progressViewStyle(.linear)
                        nowLine
                    } else if !job.failures.isEmpty {
                        Text(job.failures.prefix(2).joined(separator: " · ")).font(.caption2).foregroundStyle(.red).lineLimit(1)
                    }
                }
                trailing
            }
            if job.isActive && expanded { fileList.padding(.leading, 42) }
        }
    }

    // "Now: a.jpg · USB, b.mp4 · Wi-Fi +2"  with a chevron to expand
    @ViewBuilder private var nowLine: some View {
        let files = job.inFlight
        if !files.isEmpty {
            Button {
                if expanded { ui.expandedJobs.remove(job.id) } else { ui.expandedJobs.insert(job.id) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold))
                    Text(expanded ? "Copying \(files.count) file\(files.count == 1 ? "" : "s") now"
                                  : files.prefix(2).map { "\($0.name) · \($0.lane.rawValue)" }.joined(separator: ",  ")
                                    + (files.count > 2 ? "  +\(files.count - 2)" : ""))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide files" : "Show every file being copied")
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(job.inFlight) { f in
                HStack(spacing: 8) {
                    LaneBadge(kind: f.lane)
                    Text(f.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .leading)
                    ThinBar(fraction: f.fraction, color: f.lane == .usb ? .blue : .green)
                    Text("\(Fmt.bytes(f.done)) / \(Fmt.bytes(f.size))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 130, alignment: .trailing)
                }
            }
            let waiting = job.totalFiles - job.doneFiles - job.inFlight.count
            if waiting > 0 {
                Text("\(waiting) waiting").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if job.isActive {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.speed(job.bytesPerSecond)).font(.title3.weight(.semibold)).monospacedDigit()
                Text(lanes).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(minWidth: 110, alignment: .trailing)
            Button { center.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
        } else {
            if job.direction == .toMac, job.state == .done, let url = job.revealURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button { ui.dismissedJob = job.id } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        let (name, color): (String, Color) = switch job.state {
        case .done: ("checkmark.circle.fill", .green)
        case .failed: ("exclamationmark.triangle.fill", .orange)
        case .cancelled: ("xmark.circle", .secondary)
        default: (job.direction == .toMac ? "arrow.down.circle.fill" : "arrow.up.circle.fill", .accentColor)
        }
        Image(systemName: name).font(.title).foregroundStyle(color)
    }

    private var detail: String {
        switch job.state {
        case .preparing: return "Preparing…"
        case .running:
            var s = "\(Fmt.bytes(job.doneBytes)) of \(Fmt.bytes(job.totalBytes)) · \(job.doneFiles)/\(job.totalFiles) files"
            if let eta = job.eta { s += " · \(Fmt.duration(eta)) left" }
            return s
        case .done:
            var s = "\(job.doneFiles) files · \(Fmt.bytes(job.doneBytes)) in \(Fmt.duration(job.elapsed)) · avg \(Fmt.speed(job.averageSpeed))"
            if job.skippedFiles > 0 { s += " · \(job.skippedFiles) already there" }
            return s
        case .failed(let m): return m
        case .cancelled: return "Cancelled"
        }
    }

    private var lanes: String {
        job.laneRates.sorted { $0.key.rawValue > $1.key.rawValue }
            .map { "\($0.key.rawValue) \(String(format: "%.0f", $0.value / 1e6))" }
            .joined(separator: " · ")
    }
}

struct LaneBadge: View {
    let kind: Lane.Kind
    var body: some View {
        Text(kind.rawValue)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background((kind == .usb ? Color.blue : Color.green).opacity(0.18), in: Capsule())
            .foregroundStyle(kind == .usb ? Color.blue : Color.green)
            .frame(width: 40, alignment: .leading)
    }
}

/// Non-animated progress bar: tracks the numbers exactly, even for files that finish in under a second.
struct ThinBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color.opacity(0.85)).frame(width: max(3, g.size.width * fraction))
            }
        }
        .frame(height: 4)
        .transaction { $0.animation = nil }
    }
}
