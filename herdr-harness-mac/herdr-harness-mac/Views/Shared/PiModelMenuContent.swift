import SwiftUI

struct PiModelMenuContent: View {
    let models: [PiAvailableModel]
    let favorites: ModelFavoritesStore
    let isSelected: (PiAvailableModel) -> Bool
    let select: (PiAvailableModel) -> Void

    var body: some View {
        let favoriteModels = ModelFavoritesStore.ordered(models, favorites: favorites.ids)
        let favoriteIDs = Set(favoriteModels.map(\.id))
        let remainingModels = models.filter {
            // Favorites are already rendered above and must not appear twice.
            !favoriteIDs.contains($0.id)
        }
        let remainingModelsByProvider = Dictionary(grouping: remainingModels, by: \.provider)

        if let selected = models.first(where: isSelected) {
            Button(
                favorites.isFavorite(selected.id) ? "Unfavorite \(selected.displayName)" : "Favorite \(selected.displayName)",
                systemImage: favorites.isFavorite(selected.id) ? "star.slash" : "star"
            ) {
                favorites.toggle(selected.id)
            }
            .accessibilityIdentifier("model-toggle-current-favorite")
            Divider()
        }

        if !favoriteModels.isEmpty {
            Section("Favorites") {
                ForEach(favoriteModels) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        Label(favoriteLabel(candidate), systemImage: isSelected(candidate) ? "checkmark.circle.fill" : "star.fill")
                    }
                    .help(candidate.id)
                    .accessibilityIdentifier("model-favorite-\(candidate.id)")
                }
            }
        }

        ForEach(remainingModelsByProvider.keys.sorted(), id: \.self) { provider in
            Section(provider) {
                ForEach((remainingModelsByProvider[provider] ?? []).sorted(by: orderedByName)) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        Label(candidate.displayName, systemImage: isSelected(candidate) ? "checkmark.circle.fill" : "cpu")
                    }
                    .help(candidate.id)
                }
            }
        }

        Menu("Manage Favorites") {
            let byProvider = Dictionary(grouping: models, by: \.provider)
            ForEach(byProvider.keys.sorted(), id: \.self) { provider in
                Section(provider) {
                    ForEach((byProvider[provider] ?? []).sorted(by: orderedByName)) { candidate in
                        Button {
                            favorites.toggle(candidate.id)
                        } label: {
                            Label(candidate.displayName, systemImage: favorites.isFavorite(candidate.id) ? "star.fill" : "star")
                        }
                        .help(candidate.id)
                    }
                }
            }
        }
        .accessibilityIdentifier("model-manage-favorites")
    }

    private func favoriteLabel(_ candidate: PiAvailableModel) -> String {
        let hasDuplicateName = models.contains { $0.id != candidate.id && $0.displayName == candidate.displayName }
        return hasDuplicateName ? "\(candidate.displayName) (\(candidate.provider))" : candidate.displayName
    }

    private func orderedByName(_ lhs: PiAvailableModel, _ rhs: PiAvailableModel) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }
}
