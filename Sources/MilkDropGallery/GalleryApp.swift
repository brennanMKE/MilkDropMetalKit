import AppKit
import SwiftUI

// MilkDrop Gallery: steps through the presets in Presets/gallery.json, each showing one renderer feature, and reacts
// to an audio file it plays (or to a built-in beat it generates silently).
//
// Launch options, for automation: --select <preset file stem>  --audio <path>  --auto-advance

@main
struct GalleryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = GalleryModel(arguments: CommandLine.arguments)

    var body: some Scene {
        // One window: the renderer keeps one feedback texture, so two views can't share it.
        Window("MilkDrop Gallery", id: "gallery") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { GalleryCommands(model: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under `swift run` there's no bundle to make this a regular, foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if CommandLine.arguments.contains("--dump-views") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                for window in NSApp.windows where window.isVisible {
                    print("window \(window.frame) minSize \(window.minSize) contentMinSize \(window.contentMinSize)")
                    Self.dump(window.contentView, depth: 0)
                }
            }
        }
    }

    /// Prints the view tree with frames, for checking layout in the test VM.
    private static func dump(_ view: NSView?, depth: Int) {
        guard let view else { return }
        let name = "\(type(of: view))".prefix(90)
        print(String(repeating: "  ", count: depth) + "\(name) \(view.frame) fitting \(view.fittingSize)")
        for subview in view.subviews { dump(subview, depth: depth + 1) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct GalleryCommands: Commands {
    let model: GalleryModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Audio File…") { model.chooseAudioFile() }
                .keyboardShortcut("o")
            Button("Add Presets…") { model.choosePresets() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Playback") {
            Button("Play/Pause") { model.audio.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Use Built-in Beat") { model.audio.useBeat() }
            Divider()
            Button("Next Preset") { model.step(1) }
                .keyboardShortcut("]")
            Button("Previous Preset") { model.step(-1) }
                .keyboardShortcut("[")
            Button("Toggle Auto-Advance") { model.setAutoAdvance(!model.autoAdvance) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Preset Info") { model.showInfo.toggle() }
                .keyboardShortcut("i")
        }
    }
}
