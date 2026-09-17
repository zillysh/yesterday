import SwiftUI

/// Shelf of saved week recaps — empty for now (step 1).
struct RecapsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer()
                Text("No saved weeks yet")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Finish a week from Moments and it’ll show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MessageTheme.background.ignoresSafeArea())
            .navigationTitle("Recaps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(MessageTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
