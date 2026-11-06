import SwiftUI

@main
struct PhoneDisplayApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PhoneDisplay") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    appDelegate.onTerminate = { model.stop() }
                    if ProcessInfo.processInfo.environment["PHONEDISPLAY_AUTOSTART"] == "1"
                        || CommandLine.arguments.contains("--autostart") {
                        model.start()
                    }
                }
        }
        .defaultSize(width: 620, height: 780)
        .windowResizability(.contentSize)

        MenuBarExtra("PhoneDisplay", systemImage: "iphone.gen3") {
            Button("Show PhoneDisplay") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button(model.isRunning ? "Stop" : "Start") {
                if model.isRunning {
                    model.stop()
                } else {
                    model.start()
                }
            }
            Divider()
            Button("Quit PhoneDisplay") {
                NSApp.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}
