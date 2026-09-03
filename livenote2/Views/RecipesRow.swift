import SwiftUI

/// 채팅 홈 화면의 가로 레시피 칩 행 (빌트인 + 사용자 레시피 + See all 칩).
struct RecipesRow: View {
    @Environment(AppState.self) private var app
    var onSelect: (Recipe) -> Void
    var onSeeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recipes")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("See all") {
                    onSeeAll()
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Theme.accent)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(app.recipeStore.recipes) { recipe in
                        Button {
                            onSelect(recipe)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: recipe.icon.isEmpty ? "doc.text" : recipe.icon)
                                    .font(.callout)
                                    .foregroundStyle(Theme.accent)
                                Text(recipe.title)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .themedCard()
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onSeeAll()
                    } label: {
                        HStack(spacing: 4) {
                            Text("See all")
                                .font(.callout)
                                .foregroundStyle(Theme.accent)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .themedCard()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
