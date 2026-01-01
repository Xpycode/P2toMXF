import SwiftUI

/// Left panel showing loaded P2 cards
struct CardListView: View {
    @ObservedObject var viewModel: ConversionViewModel
    @Binding var showingP2Picker: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("P2 Cards")
                    .font(.headline)

                Spacer()

                Button {
                    showingP2Picker = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Load another P2 card")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.1))

            Divider()

            // Card list or empty state
            if viewModel.loadedCards.isEmpty {
                emptyState
            } else {
                cardList
            }
        }
        .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "sdcard")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("No Cards Loaded")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                showingP2Picker = true
            } label: {
                Label("Load P2 Card", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card List

    private var cardList: some View {
        List(viewModel.loadedCards, selection: Binding(
            get: { viewModel.activeCardId },
            set: { newId in
                if let id = newId, let card = viewModel.loadedCards.first(where: { $0.id == id }) {
                    viewModel.setActiveCard(card)
                }
            }
        )) { card in
            CardRowView(
                card: card,
                isActive: viewModel.isActiveCard(card),
                onRemove: { viewModel.removeCard(card) }
            )
            .tag(card.id)
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Card Row View

struct CardRowView: View {
    let card: P2Card
    let isActive: Bool
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Card icon
            Image(systemName: "sdcard.fill")
                .foregroundStyle(isActive ? .blue : .secondary)

            // Card info
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(card.clipCount) clips")
                    Text("•")
                    Text(card.formattedDuration)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Remove button (shown on hover)
            if isHovering {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this card")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
