import Foundation

extension ConversionViewModel {

    // MARK: - P2 Card Loading

    func loadP2Card(from url: URL) {
        // Check if this card is already loaded (by path)
        if loadedCards.contains(where: { $0.rootPath == url }) {
            errorMessage = "This P2 card is already loaded"
            return
        }

        isLoading = true
        errorMessage = nil

        // Use Task.detached to run parsing off the main thread
        // This prevents UI freezing on large P2 cards (5-30+ seconds of I/O)
        let parser = self.parser
        Task.detached {
            do {
                let card = try parser.parseP2Card(at: url)
                await MainActor.run {
                    self.loadedCards.append(card)
                    self.activeCardId = card.id
                    // Auto-select all clips in the new card
                    self.selectedClips = Set(card.clips.map { $0.id })
                    self.conversionStatus = [:]
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }


    /// Discovers and loads all P2 cards within a folder
    /// If the folder itself is a P2 card, loads just that card
    /// If the folder contains multiple P2 cards, loads all of them
    func loadP2Cards(from url: URL) {
        isLoading = true
        errorMessage = nil

        let parser = self.parser

        Task.detached {
            // Discover P2 cards in the folder
            let discoveredURLs = parser.discoverP2Cards(in: url)

            if discoveredURLs.isEmpty {
                await MainActor.run {
                    self.stopSecurityAccess(for: url)
                    self.errorMessage = "No P2 cards found in this folder"
                    self.isLoading = false
                }
                return
            }

            // Filter out already-loaded cards
            let existingPaths = await MainActor.run { Set(self.loadedCards.map { $0.rootPath }) }
            let newURLs = discoveredURLs.filter { !existingPaths.contains($0) }

            if newURLs.isEmpty {
                await MainActor.run {
                    self.stopSecurityAccess(for: url)
                    self.errorMessage = discoveredURLs.count == 1
                        ? "This P2 card is already loaded"
                        : "All \(discoveredURLs.count) P2 cards are already loaded"
                    self.isLoading = false
                }
                return
            }

            // Parse all discovered cards (in parallel for speed)
            let results = await withTaskGroup(of: Result<P2Card, Error>.self) { group -> [Result<P2Card, Error>] in
                for cardURL in newURLs {
                    group.addTask {
                        do {
                            let card = try parser.parseP2Card(at: cardURL)
                            return .success(card)
                        } catch {
                            return .failure(error)
                        }
                    }
                }

                var collected: [Result<P2Card, Error>] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            // Separate successes and failures
            var loadedCards: [P2Card] = []
            var errors: [String] = []
            for result in results {
                switch result {
                case .success(let card):
                    loadedCards.append(card)
                case .failure(let error):
                    errors.append(error.localizedDescription)
                }
            }

            // Sort by card name for consistent display
            let sortedCards = loadedCards.sorted { $0.name < $1.name }
            let errorMessages = errors

            await MainActor.run {
                // Add all successfully parsed cards
                self.loadedCards.append(contentsOf: sortedCards)

                // Make the first new card active
                if let firstCard = sortedCards.first {
                    self.activeCardId = firstCard.id
                    self.selectedClips = Set(firstCard.clips.map { $0.id })
                }

                // Track parent folder relationship for multi-card loads
                // This allows us to release parent access when all cards from it are removed
                if sortedCards.count > 1 {
                    let cardIds = Set(sortedCards.map { $0.id })
                    self.parentFolderToCards[url] = cardIds
                }

                self.conversionStatus = [:]
                self.isLoading = false

                // Show feedback about what was loaded
                if !errorMessages.isEmpty && sortedCards.isEmpty {
                    self.errorMessage = "Failed to load: \(errorMessages.first ?? "Unknown error")"
                } else if !errorMessages.isEmpty {
                    self.log("Loaded \(sortedCards.count) cards (\(errorMessages.count) failed)")
                } else if sortedCards.count > 1 {
                    self.log("Loaded \(sortedCards.count) P2 cards from \(url.lastPathComponent)")
                }
            }
        }
    }

    /// Set the active card and update selection
    func setActiveCard(_ card: P2Card) {
        activeCardId = card.id
        // Select all clips in the newly active card
        selectedClips = Set(card.clips.map { $0.id })
        conversionStatus = [:]
    }

    /// Remove a card from the loaded cards list
    func removeCard(_ card: P2Card) {
        // Release security-scoped access for this card's path
        stopSecurityAccess(for: card.rootPath)

        // Check if this card was loaded from a parent folder
        // Release parent access when the last card from it is removed
        for (parentURL, var cardIds) in parentFolderToCards {
            if cardIds.contains(card.id) {
                cardIds.remove(card.id)
                if cardIds.isEmpty {
                    // Last card from this parent - release parent access
                    stopSecurityAccess(for: parentURL)
                    parentFolderToCards.removeValue(forKey: parentURL)
                } else {
                    parentFolderToCards[parentURL] = cardIds
                }
                break
            }
        }

        loadedCards.removeAll { $0.id == card.id }

        // If we removed the active card, switch to another
        if activeCardId == card.id {
            activeCardId = loadedCards.first?.id
            if let newActive = activeCard {
                selectedClips = Set(newActive.clips.map { $0.id })
            } else {
                selectedClips = []
            }
        }
        conversionStatus = [:]
    }

    /// Check if a card is the active one
    func isActiveCard(_ card: P2Card) -> Bool {
        activeCardId == card.id || (activeCardId == nil && loadedCards.first?.id == card.id)
    }

    /// Reload the active card from disk
    func refreshActiveCard() {
        guard let card = activeCard else { return }
        let rootPath = card.rootPath
        let cardId = card.id

        isLoading = true
        errorMessage = nil

        // Use Task.detached to run parsing off the main thread
        let parser = self.parser
        Task.detached {
            do {
                let refreshedCard = try parser.parseP2Card(at: rootPath)
                await MainActor.run {
                    // Replace the old card with refreshed data
                    if let index = self.loadedCards.firstIndex(where: { $0.id == cardId }) {
                        self.loadedCards[index] = refreshedCard
                    }
                    self.activeCardId = refreshedCard.id
                    self.selectedClips = Set(refreshedCard.clips.map { $0.id })
                    self.conversionStatus = [:]
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Refresh failed: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}
