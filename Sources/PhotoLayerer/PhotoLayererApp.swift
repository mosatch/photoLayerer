import SwiftUI

@main
struct PhotoLayererApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { PhotoDocument() }) { file in
            EditorView(document: file.document)
        }
        .commands { EditorCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask for Photos access up front so the library is ready the first time it's opened.
        Task { @MainActor in await PhotoLibrary.shared.requestAccess() }
    }
}
