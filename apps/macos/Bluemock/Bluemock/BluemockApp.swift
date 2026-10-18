import SwiftUI
import ServiceManagement
import Darwin

@main
struct BluemockApp: App {
    @NSApplicationDelegateAdaptor(BluemockAppDelegate.self) private var appDelegate
    @State private var store = DeviceStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            Image(systemName: store.hasRunningDevice
                  ? "antenna.radiowaves.left.and.right.circle.fill"
                  : "antenna.radiowaves.left.and.right")
                .accessibilityLabel("Bluemock")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(store: store) }

        WindowGroup("Peripheral Editor", id: "editor", for: EditorLaunch.self) { $launch in
            EditorWindow(launch: $launch, store: store)
        }
    }
}

final class BluemockAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        Task { @MainActor in
            let store = DeviceStore.shared
            await store.refresh()
            await store.startAutostartIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DeviceStore.shared.stopAllSynchronously()
    }
}
