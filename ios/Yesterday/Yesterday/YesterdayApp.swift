import SwiftUI

@main
struct YesterdayApp: App {
    @State private var library = PhotoLibraryService.shared
    @State private var chat = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(library)
                .environment(chat)
        }
    }
}
