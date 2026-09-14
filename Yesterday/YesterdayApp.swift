import SwiftUI

@main
struct YesterdayApp: App {
    @State private var library = PhotoLibraryService.shared
    @State private var chat = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(chat)
                .environment(SavedPostsStore.shared)
                .preferredColorScheme(.dark)
        }
    }
}
