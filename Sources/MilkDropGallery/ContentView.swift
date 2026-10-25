import AppKit
import MilkMetal
import SwiftUI

struct ContentView: View {
    let model: GalleryModel

    var body: some View {
        NavigationSplitView {
            PresetList(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            VStack(spacing: 0) {
                VisualizerPane(model: model)
                TransportBar(model: model, audio: model.audio)
            }
            .frame(minWidth: 520)
        }
        .navigationTitle(model.selectedEntry?.title ?? "MilkDrop Gallery")
        .toolbar {
            ToolbarItemGroup {
                Button { model.step(-1) } label: { Label("Previous Preset", systemImage: "chevron.left") }
                    .help("Previous preset (⌘[)")
                Button { model.step(1) } label: { Label("Next Preset", systemImage: "chevron.right") }
                    .help("Next preset (⌘])")
                Toggle(isOn: Binding(get: { model.autoAdvance }, set: { model.setAutoAdvance($0) })) {
                    Label("Auto-Advance", systemImage: "timer")
                }
                .help("Move to the next preset every 20 seconds")
                Toggle(isOn: Binding(get: { model.showInfo }, set: { model.showInfo = $0 })) {
                    Label("Preset Info", systemImage: "info.circle")
                }
                .help("Show what the preset demonstrates (⌘I)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.open(urls) }
    }
}

private struct PresetList: View {
    let model: GalleryModel

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: model.selection, initial: true) { _, selection in
                    guard let selection else { return }
                    proxy.scrollTo(selection)
                }
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            ForEach(model.sections) { section in
                Section(section.name) {
                    ForEach(section.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            if !entry.summary.isEmpty {
                                Text(entry.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(entry.id)
                        .id(entry.id)
                    }
                }
            }
        }
    }
}

private struct VisualizerPane: View {
    let model: GalleryModel

    var body: some View {
        ZStack {
            Color.black
            if let renderer = model.renderer {
                MilkDropView(renderer: renderer)
            } else {
                ContentUnavailableView("Can't Render", systemImage: "exclamationmark.triangle",
                                       description: Text(model.setupError ?? ""))
                    .foregroundStyle(.white)
            }
        }
        // An overlay, so the card never adds to the pane's minimum size: the split view enforces the height content
        // needs at its narrowest, and wrapped text there pushed the transport bar off screen.
        .overlay(alignment: .topLeading) {
            if model.showInfo, let entry = model.selectedEntry {
                InfoCard(entry: entry, errors: model.presetErrors)
                    .padding(16)
            }
        }
    }
}

private struct InfoCard: View {
    let entry: GalleryEntry
    let errors: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.category.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.title)
                .font(.headline)
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.callout)
                    .lineLimit(4)
            }
            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }
}

private struct TransportBar: View {
    let model: GalleryModel
    let audio: AudioPlayer
    @State private var scrubbing: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            Button { model.chooseAudioFile() } label: { Label("Open Audio…", systemImage: "music.note") }
                .help("Choose an audio file to play (⌘O); or drop one on the window")
            Button { audio.togglePlayback() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .disabled(!audio.hasFile)
            .help("Play or pause (Space)")

            VStack(alignment: .leading, spacing: 1) {
                Text(audio.fileName ?? "Built-in beat")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = audio.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                } else if !audio.hasFile {
                    Text("Generated silently. Open an audio file to hear music.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minWidth: 160, alignment: .leading)

            if audio.hasFile {
                Slider(value: Binding(get: { scrubbing ?? audio.position }, set: { scrubbing = $0 }),
                       in: 0...max(audio.duration, 0.1)) { editing in
                    if !editing, let target = scrubbing {
                        audio.seek(to: target)
                        scrubbing = nil
                    }
                }
                .controlSize(.small)
                Text("\(Self.format(scrubbing ?? audio.position)) / \(Self.format(audio.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { audio.useBeat() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop and go back to the built-in beat")
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// `MilkView` in SwiftUI. The view draws itself on every display refresh, so there's nothing to update.
struct MilkDropView: NSViewRepresentable {
    let renderer: MilkRenderer

    func makeNSView(context: Context) -> NSView {
        (try? MilkView(renderer: renderer)) ?? NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Takes whatever space it's offered. Without this SwiftUI derives a minimum size from the view that can exceed
    /// the window, which pushed the transport bar off screen.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 360)
    }
}
