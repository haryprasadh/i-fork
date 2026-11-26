import SwiftUI
import AppKit

struct TransferBar: View {
    private let center = TransferCenter.shared
    private let ui = UIState.shared

    var body: some View {
        if let job = center.current, job.id != ui.dismissedJob {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    statusIcon(job)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(job.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(detail(job)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if job.isActive {
                            ProgressView(value: job.progress).progressViewStyle(.linear)
                        }
                        if !job.isActive, !job.failures.isEmpty {
                            Text(job.failures.prefix(2).joined(separator: " · ")).font(.caption2).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                    if job.isActive {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.speed(job.bytesPerSecond)).font(.title3.weight(.semibold)).monospacedDigit()
                            Text(lanes(job)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
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
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(.bar)
        }
    }

    @ViewBuilder private func statusIcon(_ job: TransferJob) -> some View {
        let (name, color): (String, Color) = switch job.state {
        case .done: ("checkmark.circle.fill", .green)
        case .failed: ("exclamationmark.triangle.fill", .orange)
        case .cancelled: ("xmark.circle", .secondary)
        default: (job.direction == .toMac ? "arrow.down.circle.fill" : "arrow.up.circle.fill", .accentColor)
        }
        Image(systemName: name).font(.title).foregroundStyle(color)
    }

    private func detail(_ job: TransferJob) -> String {
        switch job.state {
        case .preparing: return "Preparing…"
        case .running:
            var s = "\(Fmt.bytes(job.doneBytes)) of \(Fmt.bytes(job.totalBytes)) · \(job.doneFiles)/\(job.totalFiles) files"
            if let eta = job.eta { s += " · \(Fmt.duration(eta)) left" }
            return s
        case .done:
            var s = "\(Fmt.bytes(job.doneBytes)) in \(Fmt.duration(job.elapsed)) · avg \(Fmt.speed(job.averageSpeed))"
            if job.skippedFiles > 0 { s += " · \(job.skippedFiles) already there" }
            return s
        case .failed(let m): return m
        case .cancelled: return "Cancelled"
        }
    }

    private func lanes(_ job: TransferJob) -> String {
        job.laneRates.sorted { $0.key.rawValue > $1.key.rawValue }
            .map { "\($0.key.rawValue) \(String(format: "%.0f", $0.value / 1e6))" }
            .joined(separator: " · ")
    }
}
