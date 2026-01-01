import SwiftUI

/// Sheet showing conversion time estimate before starting
struct EstimateSheet: View {
    let estimate: ConversionEstimate
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding()

            Divider()

            // Content
            VStack(spacing: 16) {
                // Source info
                sourceInfoSection

                Divider()
                    .padding(.horizontal)

                // Estimate info
                estimateSection

                // Confidence indicator
                confidenceIndicator
            }
            .padding()

            Divider()

            // Actions
            actionButtons
                .padding()
        }
        .frame(width: 360)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "clock.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.blue)

            Text("Conversion Estimate")
                .font(.headline)

            Spacer()
        }
    }

    // MARK: - Source Info

    private var sourceInfoSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Source")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 20) {
                statItem(
                    icon: "film.stack",
                    value: "\(estimate.clipCount)",
                    label: estimate.clipCount == 1 ? "clip" : "clips"
                )

                statItem(
                    icon: "internaldrive",
                    value: estimate.formattedSize,
                    label: "total"
                )

                statItem(
                    icon: "timer",
                    value: estimate.formattedSourceDuration,
                    label: "duration"
                )
            }
        }
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Estimate Info

    private var estimateSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Estimated Time")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(estimate.formattedEstimate)
                        .font(.system(.largeTitle, design: .rounded, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(estimate.formattedSpeed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Visual indicator
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.2), lineWidth: 4)
                        .frame(width: 60, height: 60)

                    Image(systemName: "bolt.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                }
            }
        }
    }

    // MARK: - Confidence Indicator

    private var confidenceIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: estimate.confidence.icon)
                .font(.caption)
                .foregroundStyle(confidenceColor)

            Text(estimate.confidence.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(confidenceColor.opacity(0.1))
        .cornerRadius(6)
    }

    private var confidenceColor: Color {
        switch estimate.confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .gray
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Button {
                onConfirm()
                dismiss()
            } label: {
                Label("Start Conversion", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}

// MARK: - Slow Speed Warning Banner

/// Banner shown during conversion when speed is below expected
struct SlowSpeedBanner: View {
    let warning: SlowSpeedWarning
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tortoise.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(warning.message)
                    .font(.subheadline.bold())

                HStack(spacing: 8) {
                    Text(String(format: "%.1fx", warning.currentSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)

                    Text("vs expected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(format: "%.0fx", warning.expectedSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(warning.formattedRemaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.orange.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

// MARK: - Queue Estimate Summary

/// Compact estimate display for queue items
struct QueueEstimateBadge: View {
    let estimate: ConversionEstimate

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(estimate.formattedEstimate)
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .help("Estimated: \(estimate.formattedEstimate) at \(estimate.formattedSpeed)")
    }
}

#Preview("Estimate Sheet") {
    EstimateSheet(
        estimate: ConversionEstimate(
            totalBytes: 45_000_000_000,
            totalDurationSeconds: 5400,
            clipCount: 16,
            estimatedSeconds: 180,
            speedMultiplier: 30,
            confidence: .high
        ),
        onConfirm: {},
        onCancel: {}
    )
}

#Preview("Slow Speed Banner") {
    SlowSpeedBanner(
        warning: SlowSpeedWarning(
            currentSpeed: 2.3,
            expectedSpeed: 30.0,
            estimatedRemaining: 2700,
            reason: .externalDrive
        ),
        onDismiss: {}
    )
    .padding()
}
