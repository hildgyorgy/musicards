import SwiftUI

struct SyncProgressView: View {
    let title: String
    let lines: [String]
    let isRunning: Bool
    let progress: Double?
    let progressLabel: String?
    let onStop: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if isRunning && progress == nil {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(title)
                    .font(.headline)

                Spacer()

                if isRunning {
                    Button("Stop", role: .destructive) {
                        onStop()
                    }
                } else {
                    Button("Close") {
                        onClose()
                    }
                }
            }

            if isRunning, let progress {
                VStack(spacing: 6) {
                    HStack {
                        Spacer()
                        Text(
                            progressLabel ??
                                "\(Int((progress * 100).rounded()))%"
                        )
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .controlSize(.small)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index])
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: lines.count) { _, newCount in
                    guard newCount > 0 else { return }

                    proxy.scrollTo(
                        newCount - 1,
                        anchor: .bottom
                    )
                }
            }
        }
        .padding(20)
        .frame(
            minWidth: 700,
            idealWidth: 800,
            minHeight: 420,
            idealHeight: 520
        )
    }
}
