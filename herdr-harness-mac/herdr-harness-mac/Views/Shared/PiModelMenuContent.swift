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

        if !favoriteModels.isEmpty {
            Section("Favorites") {
                ForEach(favoriteModels) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        Label(candidate.displayName, systemImage: isSelected(candidate) ? "checkmark.circle.fill" : "cpu")
                    }
                    .help(candidate.id)
                    .accessibilityIdentifier("model-favorite-\(candidate.id)")
                }
            }
        }

        ForEach(remainingModelsByProvider.keys.sorted(), id: \.self) { provider in
            Section(provider) {
                ForEach(remainingModelsByProvider[provider] ?? []) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        Label(candidate.displayName, systemImage: isSelected(candidate) ? "checkmark.circle.fill" : "cpu")
                    }
                }
            }
        }

        Menu("Manage Favorites") {
            ForEach(models.sorted { lhs, rhs in
                lhs.provider == rhs.provider ? lhs.modelID < rhs.modelID : lhs.provider < rhs.provider
            }) { candidate in
                Toggle(
                    candidate.displayName,
                    isOn: Binding(
                        get: { favorites.isFavorite(candidate.id) },
                        set: { _ in favorites.toggle(candidate.id) }
                    )
                )
            }
        }
        .accessibilityIdentifier("model-manage-favorites")
    }
}
