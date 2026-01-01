import SwiftUI

/// A compact progress panel showing conversion status with metrics
/// Designed to replace the action button area in the footer during active conversion
struct ProgressControlPanel: View {
    let metrics: ProgressMetrics
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main progress bar with percentage
            HStack(spacing: 12) {
                ProgressView(value: metrics.progress)
                    .progressViewStyle(.linear)

                Text("\(Int(metrics.progress * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            // Status text and metrics row
            HStack {
                // Phase/status description
                Text(metrics.phase)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Metrics: Elapsed | Remaining | Speed
                metricsRow
            }
        }
    }

    @ViewBuilder
    private var metricsRow: some View {
        HStack(spacing: 8) {
            // Elapsed time
            MetricLabel(icon: "clock", value: metrics.formattedElapsed)

            // Estimated remaining (if available)
            if let remaining = metrics.formattedRemaining {
                Divider()
                    .frame(height: 12)
                MetricLabel(icon: "hourglass", value: "~\(remaining)")
            }

            // Speed (if available)
            if let speed = metrics.formattedSpeed {
                Divider()
                    .frame(height: 12)
                MetricLabel(icon: "speedometer", value: speed)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Small metric display with icon
private struct MetricLabel: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(value)
                .monospacedDigit()
        }
    }
}

// MARK: - Preview

#Preview("Active Conversion") {
    VStack {
        ProgressControlPanel(
            metrics: {
                var m = ProgressMetrics()
                m.progress = 0.45
                m.phase = "Rewrapping clip 3/10: 0234LZ"
                m.startTime = Date().addingTimeInterval(-125)  // 2:05 elapsed
                m.speed = "12.5x"
                m.fps = 312.5
                m.currentFrame = 4500
                m.totalFrames = 10000
                return m
            }(),
            onCancel: {}
        )
        .padding()
        .background(.ultraThinMaterial)
    }
    .frame(width: 500)
}

#Preview("Early Stage") {
    VStack {
        ProgressControlPanel(
            metrics: {
                var m = ProgressMetrics()
                m.progress = 0.02
                m.phase = "Phase 1: Rewrapping clips with BMX..."
                m.startTime = Date().addingTimeInterval(-3)
                return m
            }(),
            onCancel: {}
        )
        .padding()
        .background(.ultraThinMaterial)
    }
    .frame(width: 500)
}
