import SwiftUI
import AppKit

// MARK: - Group Header View

/// Section header for a recording group showing group info and selection controls
struct GroupHeaderView: View {
    let group: RecordGroup
    let isFullySelected: Bool
    let isPartiallySelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Selection checkbox (with mixed state support)
            Button(action: onToggle) {
                Image(systemName: checkboxIcon)
                    .foregroundStyle(isFullySelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            // Span indicator (link icon for spanned groups)
            if group.isSpanned {
                Image(systemName: "link")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("Spanned recording (camera-split)")
            }

            // Group info
            Text("Group \(group.groupIndex)")
                .font(.subheadline.bold())

            // Group type badge
            Text(group.groupTypeLabel)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(groupTypeBadgeColor.opacity(0.2))
                .foregroundStyle(groupTypeBadgeColor)
                .cornerRadius(4)

            Text("(\(group.clipCount) clips)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\u{2022}")
                .foregroundStyle(.tertiary)

            Text(group.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("\u{2022}")
                .foregroundStyle(.tertiary)

            Text("TC: \(group.startTimecode)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var groupTypeBadgeColor: Color {
        switch group.groupType {
        case .spanned: return .orange
        case .continuous: return .blue
        case .single: return .gray
        }
    }

    private var checkboxIcon: String {
        if isFullySelected {
            return "checkmark.circle.fill"
        } else if isPartiallySelected {
            return "minus.circle.fill"
        } else {
            return "circle"
        }
    }
}

// MARK: - Clip Row View

/// Single row displaying a P2 clip with thumbnails, info, and status
struct ClipRowView: View {
    let clip: P2Clip
    let isSelected: Bool
    let status: ConversionStatus?
    let thumbnailManager: ThumbnailManager

    @State private var thumbnails: ThumbnailManager.ClipThumbnails?
    @State private var isLoadingThumbnails = false

    private let thumbnailHeight: CGFloat = 45
    private let thumbnailWidth: CGFloat = 80  // 16:9 aspect at 45px height

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            // Thumbnails (first & last frame)
            HStack(spacing: 2) {
                thumbnailView(image: thumbnails?.first, label: "IN")
                thumbnailView(image: thumbnails?.last, label: "OUT")
            }

            // Clip info
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.displayName)
                    .font(.body.bold())

                Text("\(clip.startTimecode.isEmpty ? "--:--:--:--" : clip.startTimecode) \u{2022} \(clip.formattedDuration) \u{2022} \(clip.videoCodec) \u{2022} \(clip.audioChannels) ch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

            // Conversion status
            if let status = status {
                statusBadge(for: status)
            }
        }
        .padding(.vertical, 4)
        .task(id: clip.id) {
            // Lazy load thumbnails when row becomes visible
            guard thumbnails == nil else { return }
            isLoadingThumbnails = true
            thumbnails = await thumbnailManager.getThumbnails(for: clip)
            isLoadingThumbnails = false
        }
        .onDisappear {
            // Cancel pending request if row scrolls off screen
            if thumbnails == nil {
                Task {
                    await thumbnailManager.cancelRequest(for: clip.id)
                }
            }
        }
    }

    // MARK: - Thumbnail View

    @ViewBuilder
    private func thumbnailView(image: NSImage?, label: String) -> some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.1))

            if let image = image {
                // Thumbnail image
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailWidth, height: thumbnailHeight)
                    .clipped()
            } else if isLoadingThumbnails {
                // Loading spinner
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                // Placeholder
                Image(systemName: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Label overlay (IN/OUT)
            VStack {
                Spacer()
                HStack {
                    Text(label)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(2)
                    Spacer()
                }
                .padding(2)
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .cornerRadius(4)
    }

    // MARK: - Status Badge

    @ViewBuilder
    private func statusBadge(for status: ConversionStatus) -> some View {
        switch status {
        case .pending:
            Text("Pending")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .inProgress(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
            }
        case .finalizing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Finalizing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let error):
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help(error)
        }
    }
}
