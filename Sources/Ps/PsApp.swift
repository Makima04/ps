import AppKit
import ColorEngine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct PsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var studio = Studio(storageURL: ProcessInfo.processInfo.environment["PS_PROJECT_FILE"]
        .map { URL(fileURLWithPath: $0) })

    var body: some Scene {
        WindowGroup("调色工作室") {
            ContentView(studio: studio)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 760)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    studio.save()
                }
        }
        .defaultSize(width: 1380, height: 900)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销", action: studio.undo)
                    .keyboardShortcut("z")
                    .disabled(!studio.history.canUndo)
                Button("重做", action: studio.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!studio.history.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("导入照片…", action: studio.pickFiles)
                    .keyboardShortcut("o")
                Button("导出当前照片…") { studio.export(all: false) }
                    .keyboardShortcut("e")
                    .disabled(studio.photo == nil || studio.exporting)
            }
        }
    }
}
