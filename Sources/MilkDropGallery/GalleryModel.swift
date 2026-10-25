import AppKit
import Metal
import MilkMetal
import Observation
import UniformTypeIdentifiers

/// One preset in the list.
struct GalleryEntry: Identifiable, Hashable {
    let id: URL
    let title: String
    let category: String
    let summary: String
}

struct GallerySection: Identifiable {
    let name: String
    var entries: [GalleryEntry]
    var id: String { name }
}

/// Presets/gallery.json: the gallery's categories and presets, in display order.
private struct Manifest: Decodable {
    struct Item: Decodable {
        var file: String
        var title: String
        var summary: String
    }

    struct Category: Decodable {
        var name: String
        var presets: [Item]
    }

    var categories: [Category]
}

@MainActor
@Observable
final class GalleryModel {
    static let addedSection = "Your Presets"
    static let advanceInterval: Duration = .seconds(20)

    let renderer: MilkRenderer?
    let audio: AudioPlayer
    private(set) var setupError: String?
    private(set) var sections: [GallerySection] = []
    private(set) var selection: URL?
    private(set) var presetErrors: [String] = []
    private(set) var autoAdvance = false
    var showInfo = true

    @ObservationIgnored private var advanceTask: Task<Void, Never>?

    var entries: [GalleryEntry] { sections.flatMap(\.entries) }
    var selectedEntry: GalleryEntry? { entries.first { $0.id == selection } }

    init(arguments: [String]) {
        var renderer: MilkRenderer?
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
            } catch {
                setupError = "The renderer could not start: \(error)"
            }
        } else {
            setupError = "This Mac has no Metal device."
        }
        self.renderer = renderer
        audio = AudioPlayer(renderer: renderer)

        do {
            sections = try Self.loadCatalog()
        } catch {
            setupError = setupError ?? "The bundled presets could not be read: \(error)"
        }

        var args = arguments.dropFirst()[...]
        var initial: String?
        var audioPath: String?
        var advance = false
        while let arg = args.popFirst() {
            switch arg {
            case "--select": initial = args.popFirst()
            case "--audio": audioPath = args.popFirst()
            case "--auto-advance": advance = true
            default: break
            }
        }
        let start = entries.first { $0.id.deletingPathExtension().lastPathComponent == initial } ?? entries.first
        select(start?.id)
        if let audioPath { audio.open(URL(fileURLWithPath: audioPath)) }
        if advance { setAutoAdvance(true) }
    }

    // MARK: Selection

    func select(_ id: URL?) {
        guard let id, let renderer else { return }
        selection = id
        do {
            try renderer.load(MilkPreset(contentsOf: id))
            presetErrors = renderer.presetErrors
            // Shader compile errors arrive once the background compile finishes.
            Task { [weak self] in
                while renderer.isCompilingShaders { try? await Task.sleep(for: .milliseconds(50)) }
                guard let self, self.selection == id else { return }
                self.presetErrors = renderer.presetErrors
            }
        } catch {
            presetErrors = ["\(error)"]
        }
        if autoAdvance { scheduleAdvance() }
    }

    func step(_ delta: Int) {
        let all = entries
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.id == selection } ?? 0
        select(all[(current + delta + all.count) % all.count].id)
    }

    func setAutoAdvance(_ on: Bool) {
        autoAdvance = on
        advanceTask?.cancel()
        advanceTask = nil
        if on { scheduleAdvance() }
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.advanceInterval)
            guard !Task.isCancelled else { return }
            self?.step(1)
        }
    }

    // MARK: Files

    func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an audio file to play"
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        audio.open(url)
    }

    func choosePresets() {
        let panel = NSOpenPanel()
        panel.title = "Choose .milk presets or a folder of them"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "milk") ?? .data, .folder]
        guard panel.runModal() == .OK else { return }
        addPresets(panel.urls)
    }

    /// Dropped files: the first audio file plays; .milk files and folders are added to the list.
    func open(_ urls: [URL]) -> Bool {
        var handled = false
        if let audioURL = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }) {
            audio.open(audioURL)
            handled = true
        }
        let presets = urls.filter { $0.pathExtension.lowercased() == "milk" || $0.hasDirectoryPath }
        if !presets.isEmpty {
            addPresets(presets)
            handled = true
        }
        return handled
    }

    func addPresets(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL } ?? []
                found += files.filter { $0.pathExtension.lowercased() == "milk" }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if url.pathExtension.lowercased() == "milk" {
                found.append(url)
            }
        }
        let known = Set(entries.map(\.id))
        let added = found.filter { !known.contains($0) }.map {
            GalleryEntry(id: $0, title: $0.deletingPathExtension().lastPathComponent, category: Self.addedSection,
                         summary: "")
        }
        guard let first = added.first else { return }
        if let index = sections.firstIndex(where: { $0.name == Self.addedSection }) {
            sections[index].entries += added
        } else {
            sections.append(GallerySection(name: Self.addedSection, entries: added))
        }
        select(first.id)
    }

    // MARK: Catalog

    /// The bundled presets: Contents/Resources/Presets in the app, or the repo's Presets folder under `swift run`.
    private static func presetsDirectory() -> URL? {
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("Presets")]
        #if DEBUG
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Presets"))
        #endif
        return candidates.compactMap(\.self).first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("gallery.json").path)
        }
    }

    private static func loadCatalog() throws -> [GallerySection] {
        guard let directory = presetsDirectory() else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: directory.appendingPathComponent("gallery.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return manifest.categories.map { category in
            GallerySection(name: category.name, entries: category.presets.map {
                GalleryEntry(id: directory.appendingPathComponent($0.file), title: $0.title, category: category.name,
                             summary: $0.summary)
            })
        }
    }
}
