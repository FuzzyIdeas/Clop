//
//  BatchPrepView.swift
//  Clop
//
//  SwiftUI UI for batch mode: the prepare knob panel (per-type grouped forms), the results Table,
//  the quick controls bar, the action bar, and the Adjust sheet. The engine (BatchManager) is the
//  ObservableObject model; this file is pure presentation.
//

import Cocoa
import Defaults
import Foundation
import Lowtech
import SwiftUI
import System
import UniformTypeIdentifiers

// MARK: - Formatting

private let batchByteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
}()

func humanBytes(_ n: Int) -> String {
    batchByteFormatter.string(fromByteCount: Int64(max(0, n)))
}

func savedPercent(old: Int, new: Int) -> Int? {
    guard old > 0, new > 0 else { return nil }
    return Int(((1.0 - Double(new) / Double(old)) * 100).rounded())
}

private func dimensions(_ size: CGSize?) -> String? {
    guard let size, size.width > 0, size.height > 0 else { return nil }
    return "\(Int(size.width))×\(Int(size.height))"
}

// MARK: - Picker choices

enum ImageConvertChoice: String, CaseIterable, Identifiable {
    case keep, jpeg, png, webp, jxl

    var id: String {
        rawValue
    }
    var title: String {
        switch self { case .keep: "Keep format"; case .jpeg: "JPEG"; case .png: "PNG"; case .webp: "WebP"; case .jxl: "JPEG XL" }
    }
    var target: ImageConvertTarget? {
        switch self { case .keep: nil; case .jpeg: .jpeg; case .png: .png; case .webp: .webp; case .jxl: .jxl }
    }

    static func from(_ t: ImageConvertTarget?) -> ImageConvertChoice {
        switch t { case nil: .keep; case .jpeg: .jpeg; case .png: .png; case .webp: .webp; case .jxl: .jxl }
    }
}

enum VideoEncoderChoice: String, CaseIterable, Identifiable {
    case adaptive, faster, smaller, lossless

    var id: String {
        rawValue
    }
    var title: String {
        switch self { case .adaptive: "Adaptive"; case .faster: "Faster"; case .smaller: "Smaller file"; case .lossless: "Visually lossless" }
    }
    var tier: CompressionTier {
        switch self { case .adaptive: .adaptive; case .faster: .fast; case .smaller: .smaller; case .lossless: .lossless }
    }

    static func from(_ tier: CompressionTier) -> VideoEncoderChoice {
        switch tier { case .adaptive: .adaptive; case .fast: .faster; case .smaller, .custom: .smaller; case .lossless: .lossless }
    }
}

enum VideoConvertChoice: String, CaseIterable, Identifiable {
    case keep, mp4, hevc, av1, webm

    var id: String {
        rawValue
    }
    var title: String {
        switch self { case .keep: "Keep format"; case .mp4: "MP4"; case .hevc: "HEVC"; case .av1: "AV1"; case .webm: "WebM" }
    }
    var target: VideoConvertTarget? {
        switch self { case .keep: nil; case .mp4: .mp4; case .hevc: .hevc; case .av1: .av1; case .webm: .webm }
    }

    static func from(_ t: VideoConvertTarget?) -> VideoConvertChoice {
        switch t { case nil: .keep; case .mp4: .mp4; case .hevc: .hevc; case .av1: .av1; case .webm: .webm }
    }
}

enum PDFDPIChoice: String, CaseIterable, Identifiable {
    case adaptive, dpi300, dpi250, dpi200, dpi150, dpi100, dpi72, dpi48, stepDown

    var id: String {
        rawValue
    }
    var title: String {
        switch self {
        case .adaptive: "Adaptive"; case .stepDown: "Step down per file"
        case .dpi300: "300 DPI"; case .dpi250: "250 DPI"; case .dpi200: "200 DPI"; case .dpi150: "150 DPI"
        case .dpi100: "100 DPI"; case .dpi72: "72 DPI"; case .dpi48: "48 DPI"
        }
    }
    var mode: PDFDPIMode {
        switch self {
        case .adaptive: .adaptive; case .stepDown: .stepDown
        case .dpi300: .fixed(300); case .dpi250: .fixed(250); case .dpi200: .fixed(200); case .dpi150: .fixed(150)
        case .dpi100: .fixed(100); case .dpi72: .fixed(72); case .dpi48: .fixed(48)
        }
    }

    static func from(_ dpi: Int) -> PDFDPIChoice {
        switch dpi { case PDF_DPI_ADAPTIVE: .adaptive; case 300: .dpi300; case 250: .dpi250; case 200: .dpi200; case 150: .dpi150; case 100: .dpi100; case 72: .dpi72; case 48: .dpi48; default: .adaptive }
    }

    static func from(_ mode: PDFDPIMode) -> PDFDPIChoice {
        switch mode {
        case .useDefault, .adaptive: .adaptive
        case .stepDown: .stepDown
        case let .fixed(n): from(n)
        }
    }
}

enum AudioFormatChoice: String, CaseIterable, Identifiable {
    case keep, aac, mp3, opus, wav, flac

    var id: String {
        rawValue
    }
    var title: String {
        switch self { case .keep: "Keep format"; case .aac: "AAC"; case .mp3: "MP3"; case .opus: "Opus"; case .wav: "WAV"; case .flac: "FLAC" }
    }
    var format: AudioFormat? {
        switch self { case .keep: nil; case .aac: .aac; case .mp3: .mp3; case .opus: .opus; case .wav: .wav; case .flac: .flac }
    }

    static func from(_ f: AudioFormat?) -> AudioFormatChoice {
        switch f { case nil, .sameAsInput: .keep; case .aac: .aac; case .mp3: .mp3; case .opus: .opus; case .wav: .wav; case .flac: .flac; case .aiff: .keep }
    }
}

enum LoudnessChoice: String, CaseIterable, Identifiable {
    case off, streaming, appleMusic, podcast, broadcast

    var id: String {
        rawValue
    }
    var title: String {
        switch self { case .off: "No normalisation"; case .streaming: "Streaming (−14 LUFS)"; case .appleMusic: "Apple Music (−16)"; case .podcast: "Podcast (−19)"; case .broadcast: "Broadcast (−23)" }
    }
    var lufs: Double? {
        switch self { case .off: nil; case .streaming: -14; case .appleMusic: -16; case .podcast: -19; case .broadcast: -23 }
    }

    static func from(_ lufs: Double?) -> LoudnessChoice {
        switch lufs { case -14: .streaming; case -16: .appleMusic; case -19: .podcast; case -23: .broadcast; default: .off }
    }
}

// MARK: - Editable params model

@MainActor final class BatchParamsModel: ObservableObject {
    @Published var outputFolder: String?

    @Published var imageCompression = 30.0
    @Published var imageConvert: ImageConvertChoice = .keep
    @Published var imageAdaptive = false
    @Published var imageDownscale = 0.0 // 0 = no downscale … 1 = 0.05×
    @Published var imageLongEdge = 0

    @Published var videoCompression = 50.0
    @Published var videoEncoder: VideoEncoderChoice = .adaptive
    @Published var videoConvert: VideoConvertChoice = .keep
    @Published var videoFPSCap = false
    @Published var videoFPS = 60
    @Published var videoRemoveAudio = false
    @Published var videoDownscale = 0.0
    @Published var videoLongEdge = 0

    @Published var pdfDPI: PDFDPIChoice = .adaptive

    @Published var audioFormat: AudioFormatChoice = .keep
    @Published var audioCompression = 35.0
    @Published var audioBitrate = 0
    @Published var audioConvertLossless = false
    @Published var audioLoudness: LoudnessChoice = .off
    @Published var audioCover: AudioCoverArtBehaviour = .optimise
    @Published var audioCoverSize = 0

    @Published var imageKeepIfLarger = true
    @Published var videoKeepIfLarger = true
    @Published var audioKeepIfLarger = true

    /// Greying mirrors the engine's real precedence.
    var audioLossless: Bool {
        audioFormat.format?.isLossless ?? false
    }
    var audioCompressionDisabled: Bool {
        audioLossless || audioBitrate > 0
    }
    var audioBitrateDisabled: Bool {
        audioLossless
    }
    var audioCoverDisabled: Bool {
        !(audioFormat.format?.supportsCoverArt ?? true)
    }
    var audioCoverSizeDisabled: Bool {
        audioCoverDisabled || audioCover != .optimise
    }
    var videoCompressionDisabled: Bool {
        videoEncoder == .lossless
    }
    var imageDownscaleDisabled: Bool {
        imageLongEdge > 0
    }
    var imageLongEdgeDisabled: Bool {
        imageDownscale > 0.001
    }
    var videoDownscaleDisabled: Bool {
        videoLongEdge > 0
    }
    var videoLongEdgeDisabled: Bool {
        videoDownscale > 0.001
    }
    var imageKeepIfLargerDisabled: Bool {
        imageConvert == .keep
    }
    var videoKeepIfLargerDisabled: Bool {
        videoConvert == .keep
    }
    var audioKeepIfLargerDisabled: Bool {
        audioFormat == .keep
    }

    var audioBitrateRange: ClosedRange<Int> {
        if let r = audioFormat.format?.bitrateRange { return r.lo ... r.hi }
        return 32 ... 320
    }

    func seedFromDefaults() {
        imageCompression = Double(Defaults[.imageCompression].factor)
        imageAdaptive = Defaults[.adaptiveImageSize] || Defaults[.imageCompression].tier == .adaptive
        videoCompression = Double(Defaults[.videoCompression].factor)
        videoEncoder = .from(Defaults[.videoCompression].tier)
        videoFPSCap = Defaults[.capVideoFPS]
        videoFPS = Int(Defaults[.targetVideoFPS])
        videoRemoveAudio = Defaults[.removeAudioFromVideos]
        pdfDPI = .from(Defaults[.pdfDPI])
        audioCompression = Double(Defaults[.audioCompression].factor)
        audioCover = Defaults[.audioCoverArt]
    }

    /// Re-clamp a manually-set bitrate into the current format's range. A SwiftUI Slider won't write
    /// back an out-of-range bound value, so without this the label could show e.g. 320 for an AAC
    /// encode capped at 256 (and serialise the wrong number).
    func clampAudioBitrateToFormat() {
        guard audioBitrate > 0 else { return }
        let r = audioBitrateRange
        audioBitrate = min(max(audioBitrate, r.lowerBound), r.upperBound)
    }

    /// Seed every control from an existing config, so the Adjust panel starts from what's already
    /// applied (and change-detection can tell what the user actually touched).
    func seed(from p: BatchParams) {
        outputFolder = p.output
        imageCompression = Double(p.images.compression?.factor ?? Defaults[.imageCompression].factor)
        imageAdaptive = p.images.adaptive ?? false
        imageConvert = .from(p.images.convertTo)
        imageDownscale = sliderPos(p.images.downscaleFactor)
        imageLongEdge = p.images.maxLongEdge ?? 0
        imageKeepIfLarger = p.images.allowLarger

        videoCompression = Double(p.video.compression?.factor ?? Defaults[.videoCompression].factor)
        videoEncoder = .from(p.video.compression?.tier ?? .adaptive)
        videoConvert = .from(p.video.convertTo)
        videoFPSCap = p.video.fpsCap != nil
        videoFPS = p.video.fpsCap ?? Int(Defaults[.targetVideoFPS])
        videoRemoveAudio = p.video.removeAudio
        videoDownscale = sliderPos(p.video.downscaleFactor)
        videoLongEdge = p.video.maxLongEdge ?? 0
        videoKeepIfLarger = p.video.allowLarger

        pdfDPI = .from(p.pdf.dpiMode)

        audioFormat = .from(p.audio.format)
        audioCompression = Double(p.audio.compression?.factor ?? Defaults[.audioCompression].factor)
        audioBitrate = p.audio.bitrate ?? 0
        audioConvertLossless = p.audio.convertLossless
        audioLoudness = .from(p.audio.loudnorm)
        audioCover = p.audio.coverArt ?? .optimise
        audioCoverSize = p.audio.coverArtMaxLongEdge ?? 0
        audioKeepIfLarger = p.audio.allowLarger
    }

    func toBatchParams() -> BatchParams {
        var p = BatchParams.fromDefaults()
        p.output = outputFolder

        p.images.compression = CompressionQuality(tier: .custom, factor: Int(imageCompression))
        p.images.adaptive = imageAdaptive
        p.images.convertTo = imageConvert.target
        p.images.maxLongEdge = imageLongEdge > 0 ? imageLongEdge : nil
        p.images.downscaleFactor = factor(imageDownscale, longEdge: p.images.maxLongEdge)
        p.images.allowLarger = imageConvert != .keep && imageKeepIfLarger

        p.video.compression = CompressionQuality(tier: videoEncoder.tier, factor: Int(videoCompression))
        p.video.convertTo = videoConvert.target
        p.video.fpsCap = videoFPSCap && videoFPS > 0 ? videoFPS : nil
        p.video.removeAudio = videoRemoveAudio
        p.video.maxLongEdge = videoLongEdge > 0 ? videoLongEdge : nil
        p.video.downscaleFactor = factor(videoDownscale, longEdge: p.video.maxLongEdge)
        p.video.allowLarger = videoConvert != .keep && videoKeepIfLarger

        p.pdf.dpiMode = pdfDPI.mode

        p.audio.format = audioFormat.format
        p.audio.compression = CompressionQuality(tier: .custom, factor: Int(audioCompression))
        p.audio.bitrate = audioBitrate > 0 ? audioBitrate : nil
        p.audio.convertLossless = audioConvertLossless
        p.audio.loudnorm = audioLoudness.lufs
        p.audio.coverArt = audioCover
        p.audio.coverArtMaxLongEdge = audioCoverSize > 0 ? audioCoverSize : nil
        p.audio.allowLarger = audioFormat != .keep && audioKeepIfLarger
        return p
    }

    private func factor(_ slider: Double, longEdge: Int?) -> Double? {
        guard longEdge == nil else { return nil }
        let f = ((1.0 - slider * 0.95) * 100).rounded() / 100 // 2 decimals → stable round-trip with seed()
        return f < 0.999 ? f : nil
    }

    private func sliderPos(_ factor: Double?) -> Double {
        guard let factor, factor < 0.999 else { return 0 }
        return min(max((1.0 - factor) / 0.95, 0), 1)
    }

}

// MARK: - Root

struct BatchRootView: View {
    @ObservedObject var manager: BatchManager

    var body: some View {
        Group {
            if manager.isPreparing {
                BatchPrepContent(manager: manager)
            } else {
                BatchResultsContent(manager: manager)
            }
        }
        .frame(minWidth: 1080, minHeight: 480)
    }
}

// MARK: - Prepare

struct BatchPrepContent: View {
    @ObservedObject var manager: BatchManager

    var body: some View {
        VStack(spacing: 0) {
            if !manager.phase.isEmpty {
                Spacer()
                ProgressView(manager.phase).controlSize(.small)
                Spacer()
            } else if manager.items.isEmpty {
                dropZone
            } else {
                // Extracted into its own view so dragging a parameter slider (which republishes
                // `form`) doesn't re-run this body and re-sort/re-render the whole file table.
                BatchPrepFilesTable(manager: manager)
                Divider()
                // Fixed-size inline panel (no scroll), like the results view's "Adjust optimisation
                // parameters" panel. The window min height (set below) keeps the cards fully visible.
                BatchParamColumns(form: form, present: present).padding(16)
            }

            Divider()
            footer
        }
        .onAppear {
            form.seedFromDefaults()
            setWindowMinHeight(manager.items.isEmpty ? 500 : 650)
        }
        .onChange(of: manager.items.isEmpty) { empty in
            setWindowMinHeight(empty ? 500 : 650)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    @StateObject private var form = BatchParamsModel()
    @State private var dropTargeted = false

    private var present: PresentTypes {
        PresentTypes(manager.items)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            SwiftUI.Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop files and folders here")
                .font(.title2.weight(.medium))
            Text("Images, videos, PDFs and audio are added; everything else is ignored. Drop more anytime to keep adding.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9]))
                .foregroundStyle(.quaternary)
                .padding(24)
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !manager.phase.isEmpty {
                Text(manager.phase).foregroundStyle(.secondary)
            } else {
                Text("\(manager.items.count) file\(manager.items.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if !manager.items.isEmpty {
                    Text("·  drop to add more, select and ⌫ to remove files")
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !manager.items.isEmpty {
                Button("Reset") { manager.reset() }
            }
            Button("Cancel") { manager.windowController?.window?.close() }
                .keyboardShortcut(.cancelAction)
            Button("Optimise") { manager.beginProcessing(params: form.toBatchParams()) }
                .keyboardShortcut(.defaultAction)
                .disabled(manager.items.isEmpty || !manager.phase.isEmpty)
        }
        .padding(12)
    }

    private func setWindowMinHeight(_ h: CGFloat) {
        guard let window = manager.windowController?.window else { return }
        window.contentMinSize.height = h
        guard window.frame.height < h else { return }
        // Defer the animated resize to the next run-loop tick. `animate: true` spins a nested
        // run loop, and calling it synchronously from a SwiftUI update (.onChange/.onAppear, or
        // while a drop's commit animation is being driven) re-enters the view-graph renderer
        // mid-render and dereferences a null pointer (CLOP-24P).
        DispatchQueue.main.async {
            var frame = window.frame
            frame.origin.y -= (h - frame.height)
            frame.size.height = h
            window.setFrame(frame, display: true, animate: true)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let relevant = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !relevant.isEmpty else { return false }
        Task {
            var paths: [FilePath] = []
            for provider in relevant {
                guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                      let path = item.existingFilePath else { continue }
                paths.append(path)
            }
            guard !paths.isEmpty else { return }
            await MainActor.run { manager.add(paths: paths, source: .dropZone) }
        }
        return true
    }
}

// MARK: - Prepare file table (extracted so parameter-slider changes don't re-render/re-sort it)

private struct BatchPrepFilesTable: View {
    @ObservedObject var manager: BatchManager

    var body: some View {
        // Sortable columns so you can group by type/size and quickly select-and-remove specific kinds.
        Table(manager.items.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                Text(item.name).lineLimit(1).truncationMode(.middle).help(item.source.string)
            }
            TableColumn("Type", value: \.formatKey) { item in
                Text(item.oldFormat ?? "").foregroundStyle(.secondary)
            }.width(min: 70, ideal: 90)
            TableColumn("Size", value: \.sizeKey) { item in
                Text(humanBytes(item.oldBytes)).monospacedDigit().foregroundStyle(.secondary)
            }.width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: BatchItem.ID.self) { ids in
            Button("Remove from batch") { manager.remove(ids: Array(ids)); selection.subtract(ids) }
                .disabled(ids.isEmpty)
        }
        .onDeleteCommand { if !selection.isEmpty { manager.remove(ids: Array(selection)); selection = [] } }
    }

    @State private var selection = Set<BatchItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\BatchItem.name, order: .forward)]

}

// MARK: - Param columns (shared by prepare + adjust)

struct PresentTypes {
    init(_ items: [BatchItem]) {
        for it in items {
            if it.type.isImage { image = true }
            if it.type.isVideo { video = true }
            if it.type.isPDF { pdf = true }
            if it.type.isAudio { audio = true }
        }
    }

    var image = false, video = false, pdf = false, audio = false
}

struct BatchParamColumns: View {
    @ObservedObject var form: BatchParamsModel

    let present: PresentTypes

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OutputRow(form: form)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    imageCard
                    pdfCard
                }
                videoCard
                audioCard
            }
        }
    }

    private var imageCard: some View {
        ParamCard("Images", icon: "photo", dimmed: !present.image) {
            ParamRow("Compression") { compressionSlider($form.imageCompression) }
            Divider()
            ParamRow("Convert to") { choicePicker($form.imageConvert, ImageConvertChoice.allCases) { $0.title } }
            Divider()
            ParamRow("Downscale", disabled: form.imageDownscaleDisabled) { downscaleSlider($form.imageDownscale) }
            Divider()
            ParamRow("Max long edge", disabled: form.imageLongEdgeDisabled) { numberSuffix($form.imageLongEdge, "px") }
            Divider()
            ToggleRow("Adaptive (PNG ↔ JPEG)", $form.imageAdaptive)
            Divider()
            ToggleRow("Keep if larger", $form.imageKeepIfLarger, disabled: form.imageKeepIfLargerDisabled)
        }
        .frame(width: 330)
    }

    private var pdfCard: some View {
        ParamCard("PDF", icon: "doc.text", dimmed: !present.pdf) {
            ParamRow("Resolution") { choicePicker($form.pdfDPI, PDFDPIChoice.allCases) { $0.title } }
        }
        .frame(width: 330)
    }

    private var videoCard: some View {
        ParamCard("Video", icon: "film", dimmed: !present.video) {
            ParamRow("Compression", disabled: form.videoCompressionDisabled) { compressionSlider($form.videoCompression) }
            Divider()
            ParamRow("Convert to") { choicePicker($form.videoConvert, VideoConvertChoice.allCases) { $0.title } }
            Divider()
            ParamRow("Downscale", disabled: form.videoDownscaleDisabled) { downscaleSlider($form.videoDownscale) }
            Divider()
            ParamRow("Max long edge", disabled: form.videoLongEdgeDisabled) { numberSuffix($form.videoLongEdge, "px") }
            Divider()
            ParamRow("Encoder") { choicePicker($form.videoEncoder, VideoEncoderChoice.allCases) { $0.title } }
            Divider()
            ParamRow("Frame rate") {
                HStack(spacing: 6) {
                    numberField($form.videoFPS).disabled(!form.videoFPSCap)
                    Text("fps").foregroundStyle(.tertiary)
                    Toggle("", isOn: $form.videoFPSCap).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            Divider()
            ToggleRow("Remove audio", $form.videoRemoveAudio)
            Divider()
            ToggleRow("Keep if larger", $form.videoKeepIfLarger, disabled: form.videoKeepIfLargerDisabled)
        }
        .frame(width: 350)
    }

    private var audioCard: some View {
        ParamCard("Audio", icon: "music.note", dimmed: !present.audio) {
            ParamRow("Compression", disabled: form.audioCompressionDisabled) { compressionSlider($form.audioCompression) }
            Divider()
            ParamRow("Format") { choicePicker($form.audioFormat, AudioFormatChoice.allCases) { $0.title } }
            Divider()
            ParamRow("Bitrate", disabled: form.audioBitrateDisabled) { bitrateSlider($form.audioBitrate, range: form.audioBitrateRange) }
            Divider()
            ParamRow("Loudness") { choicePicker($form.audioLoudness, LoudnessChoice.allCases) { $0.title } }
            Divider()
            ParamRow("Cover art", disabled: form.audioCoverDisabled) {
                Picker("", selection: $form.audioCover) { ForEach(AudioCoverArtBehaviour.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().fixedSize()
            }
            Divider()
            ParamRow("Cover size", disabled: form.audioCoverSizeDisabled) { numberSuffix($form.audioCoverSize, "px") }
            Divider()
            ToggleRow("Convert WAV / AIFF / FLAC", $form.audioConvertLossless)
            Divider()
            ToggleRow("Keep if larger", $form.audioKeepIfLarger, disabled: form.audioKeepIfLargerDisabled)
        }
        .frame(width: 350)
        .onChange(of: form.audioFormat) { _ in form.clampAudioBitrateToFormat() }
    }
}

private struct OutputRow: View {
    @ObservedObject var form: BatchParamsModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Save to").foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { form.outputFolder == nil ? 0 : 1 },
                set: { if $0 == 0 { form.outputFolder = nil } else { pickingFolder = true } }
            )) {
                Text("In place").tag(0)
                Text("To folder…").tag(1)
            }
            .labelsHidden()
            .fixedSize()
            if let folder = form.outputFolder {
                Text(URL(fileURLWithPath: folder).lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { form.outputFolder = url.path }
        }
    }

    @State private var pickingFolder = false

}

// MARK: - Grouped card primitives (System Settings look)

struct ParamCard<Content: View>: View {
    init(_ title: String, icon: String, dimmed: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.dimmed = dimmed
        self.content = content
    }

    let title: String
    let icon: String
    let dimmed: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SwiftUI.Image(systemName: icon).foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .padding(.leading, 2)

            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
        }
        .disabled(dimmed)
        .opacity(dimmed ? 0.5 : 1)
    }
}

struct ParamRow<Control: View>: View {
    init(_ label: String, disabled: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.disabled = disabled
        self.control = control
    }

    let label: String
    let disabled: Bool
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            control()
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .padding(.horizontal, 12)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

struct ToggleRow: View {
    init(_ label: String, _ isOn: Binding<Bool>, disabled: Bool = false) {
        self.label = label
        _isOn = isOn
        self.disabled = disabled
    }

    @Binding var isOn: Bool

    let label: String
    let disabled: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(maxWidth: .infinity, minHeight: 36)
        .padding(.horizontal, 12)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

private func choicePicker<C: CaseIterable & Identifiable & Hashable>(
    _ selection: Binding<C>, _ cases: C.AllCases, _ title: @escaping (C) -> String
) -> some View where C.AllCases: RandomAccessCollection {
    Picker("", selection: selection) {
        ForEach(cases) { Text(title($0)).tag($0) }
    }
    .labelsHidden()
    .fixedSize()
}

private func compressionSlider(_ value: Binding<Double>) -> some View {
    CommitCompressionSlider(value: value)
}
private func downscaleSlider(_ value: Binding<Double>) -> some View {
    CommitDownscaleSlider(value: value)
}

/// The batch parameter panel is a deep tree of Pickers/Toggles/styled cards, so binding a Slider straight
/// to the form re-rendered the WHOLE panel on every drag tick (~1000 sub-view updates per tick in the
/// Instruments trace → visible lag). These wrappers keep the drag in local @State and only write the form
/// on release, so a drag re-renders just the slider. Batch sliders don't auto-reoptimise on change, so
/// deferring the commit has no functional downside.
private struct CommitCompressionSlider: View {
    @Binding var value: Double

    var body: some View {
        let shown = drag ?? value
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { drag ?? value }, set: { drag = $0 }),
                in: 0 ... 100,
                onEditingChanged: { editing in if !editing, let d = drag { value = d; drag = nil } }
            )
            .frame(width: 120)
            Text("\(Int(shown))").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
        }
    }

    @State private var drag: Double?
}

private struct CommitDownscaleSlider: View {
    @Binding var value: Double

    var body: some View {
        let shown = drag ?? value
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { drag ?? value }, set: { drag = $0 }),
                in: 0 ... 1,
                onEditingChanged: { editing in if !editing, let d = drag { value = d; drag = nil } }
            )
            .frame(width: 120)
            Text(String(format: "%.2f×", 1.0 - shown * 0.95)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }

    @State private var drag: Double?
}

private func numberField(_ value: Binding<Int>) -> some View {
    TextField("", value: value, format: .number.grouping(.never))
        .multilineTextAlignment(.trailing)
        .frame(width: 56)
        .textFieldStyle(.roundedBorder)
}

/// Continuous bitrate slider (2 kbps steps) that snaps to the common bitrates. 0 = Auto (use the
/// compression factor instead). Range follows the chosen output format.
private func bitrateSlider(_ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
    CommitBitrateSlider(value: value, range: range)
}

private struct CommitBitrateSlider: View {
    @Binding var value: Int

    let range: ClosedRange<Int>

    var body: some View {
        let shown = drag.map { snapBitrate(Int($0.rounded()), range: range) } ?? value
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { drag ?? Double(value) }, set: { drag = $0 }),
                in: 0 ... Double(range.upperBound), step: 2,
                onEditingChanged: { editing in if !editing, let d = drag { value = snapBitrate(Int(d.rounded()), range: range); drag = nil } }
            ).frame(width: 120)
            Text(shown == 0 ? "Auto" : "\(shown)").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }

    @State private var drag: Double?
}

private func snapBitrate(_ v: Int, range: ClosedRange<Int>) -> Int {
    if v <= 0 { return 0 }
    let common = [32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320].filter { range.contains($0) }
    let clamped = max(range.lowerBound, min(range.upperBound, v))
    if let near = common.min(by: { abs($0 - clamped) < abs($1 - clamped) }), abs(near - clamped) <= 3 { return near }
    return clamped
}

private func numberSuffix(_ value: Binding<Int>, _ suffix: String) -> some View {
    HStack(spacing: 6) {
        numberField(value)
        Text(suffix).foregroundStyle(.tertiary)
    }
}

// MARK: - Results

struct BatchResultsContent: View {
    @ObservedObject var manager: BatchManager

    var body: some View {
        VStack(spacing: 0) {
            // Extracted into its own view so changing a slider in the adjust panel (which republishes
            // `adjustForm`) doesn't re-run the whole results body and re-sort/re-render the table.
            BatchResultsTable(manager: manager, selection: $selection)
            if showAdjust {
                Divider()
                adjustPanel
            }
            Divider()
            controlsBar
            Divider()
            actionBar
        }
        .background {
            // cmd-D compares the single selected row (matches the row context menu).
            Button("") { if selection.count == 1, let id = selection.first { manager.compareItem(id: id) } }
                .keyboardShortcut("d", modifiers: .command)
                .hidden()
                .disabled(selection.count != 1 || !manager.canReapply)
        }
        .onChange(of: showAdjust) { expanded in setWindowMinHeight(expanded ? 750 : 500) }
        .onAppear { installSpaceMonitor() }
        .onDisappear { removeSpaceMonitor() }
        .sheet(isPresented: $showFailures) {
            BatchFailuresSheet(manager: manager)
        }
    }

    @StateObject private var adjustForm = BatchParamsModel()
    @State private var selection = Set<BatchItem.ID>()
    @State private var showAdjust = false
    @State private var showFailures = false
    @State private var confirmDeleteBackups = false
    @State private var spaceMonitor: Any?

    private var selectedItems: [BatchItem] {
        manager.items.filter { selection.contains($0.id) }
    }

    // MARK: Change detection (only re-optimise file types whose params actually changed)

    private var changedTypes: Set<BatchTypeKey> {
        let cur = manager.params
        let new = adjustForm.toBatchParams()
        if new.output != cur.output { return Set(BatchTypeKey.allCases) }
        var s = Set<BatchTypeKey>()
        if new.images != cur.images { s.insert(.image) }
        if new.video != cur.video { s.insert(.video) }
        if new.pdf != cur.pdf { s.insert(.pdf) }
        if new.audio != cur.audio { s.insert(.audio) }
        return s
    }

    private var affectedSummary: String {
        let ids = Set(affectedIDs(scope: nil))
        guard !ids.isEmpty else { return "No changes to apply" }
        var media = 0, docs = 0
        for item in manager.items where ids.contains(item.id) {
            switch batchTypeKey(item.type) {
            case .audio, .video: media += 1
            case .image, .pdf: docs += 1
            case nil: break
            }
        }
        var parts: [String] = []
        if media > 0 { parts.append("\(media) audio/video file\(media == 1 ? "" : "s")") }
        if docs > 0 { parts.append("\(docs) image\(docs == 1 ? "" : "s")/PDF\(docs == 1 ? "" : "s")") }
        return "Will re-optimise " + parts.joined(separator: ", ")
    }

    private var canTune: Bool {
        manager.canReapply && !manager.isRunning && !manager.isRestoring
    }

    /// Fixed-size inline panel (no scroll): the per-type cards fit the window width.
    private var adjustPanel: some View {
        VStack(spacing: 0) {
            BatchParamColumns(form: adjustForm, present: PresentTypes(manager.items)).padding(16)
            Divider()
            HStack {
                Text(affectedSummary).foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Apply to selection") { applyAdjust(Array(selection)) }
                    .disabled(changedTypes.isEmpty || selection.isEmpty)
                Button("Apply to all") { applyAdjust(nil) }
                    .disabled(changedTypes.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            batchProgress
            if manager.aggregate.savedBytes > 0 { savingsPills }
            if !manager.canReapply { Text("Backups deleted, re-running unavailable").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button {
                toggleAdjust()
            } label: {
                Label(showAdjust ? "Hide parameters" : "Adjust optimisation parameters…", systemImage: "slider.horizontal.3")
            }
            .disabled(!canTune)
            Button("Cancel") { manager.cancel() }.disabled(!manager.isRunning)
        }
        .padding(12)
    }

    @ViewBuilder private var batchProgress: some View {
        let a = manager.aggregate
        if manager.isRunning || !manager.phase.isEmpty {
            HStack(spacing: 8) {
                ProgressView(value: a.overallFraction).frame(width: 120)
                Text(manager.phase.isEmpty ? "\(a.finished)/\(a.total)" : manager.phase)
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if a.total > 0 {
            Label("\(a.done) done\(a.failed > 0 ? ", \(a.failed) failed" : "")", systemImage: a.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout).foregroundStyle(a.failed > 0 ? .orange : .green)
        }
    }

    private var savingsPills: some View {
        let a = manager.aggregate
        let pct = Int((a.savedFraction * 100).rounded())
        return HStack(spacing: 6) {
            pill(humanBytes(a.totalOldBytes), .red)
            SwiftUI.Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
            pill(humanBytes(a.totalNewBytes), .green)
            pill("−\(pct)%", .green, prominent: true)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Show in Finder") { batchReveal(selectedItems) }.disabled(selection.isEmpty)
            Button("Open") { BatchQuickLooker.quicklook(batchResultURLs(selectedItems)) }.disabled(selection.isEmpty)
            Button("Copy") { batchCopyFiles(selectedItems) }.disabled(selection.isEmpty)
            if manager.aggregate.failed > 0 {
                Button {
                    showFailures = true
                } label: {
                    Label("\(manager.aggregate.failed) failed", systemImage: "exclamationmark.triangle.fill")
                }
                .tint(.orange)
            }
            Spacer()
            Button("Restore originals") { manager.restoreFromBackup(toSelection: selection.isEmpty ? nil : Array(selection)) }
                .disabled(!canTune)
            Button("Show backups in Finder") { if let url = manager.backupDirURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                .disabled(manager.backupDirURL == nil)
            Button("Delete backups", role: .destructive) { confirmDeleteBackups = true }
                .disabled(!manager.canDeleteBackups)
                .confirmationDialog("Delete the backups for this batch?", isPresented: $confirmDeleteBackups, titleVisibility: .visible) {
                    Button("Delete backups", role: .destructive) { manager.deleteBackups() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Clop keeps a pristine copy of every original so you can re-run with different settings or restore them. Deleting the backups frees that space but means you can no longer re-compress or restore these files from Clop."
                    )
                }
        }
        .padding(12)
    }

    private func pill(_ text: String, _ color: Color, prominent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: prominent ? .semibold : .regular)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(prominent ? 0.22 : 0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private func setWindowMinHeight(_ h: CGFloat) {
        guard let window = manager.windowController?.window else { return }
        window.contentMinSize.height = h
        guard window.frame.height < h else { return }
        // Defer the animated resize to the next run-loop tick. `animate: true` spins a nested
        // run loop, and calling it synchronously from a SwiftUI update (.onChange/.onAppear, or
        // while a drop's commit animation is being driven) re-enters the view-graph renderer
        // mid-render and dereferences a null pointer (CLOP-24P).
        DispatchQueue.main.async {
            var frame = window.frame
            frame.origin.y -= (h - frame.height)
            frame.size.height = h
            window.setFrame(frame, display: true, animate: true)
        }
    }

    /// Space quick-looks the selection — but never steal space from a focused text field (Adjust panel).
    private func installSpaceMonitor() {
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.window === manager.windowController?.window else { return event }
            if let responder = event.window?.firstResponder, responder is NSText || responder is NSTextView { return event }
            let urls = batchResultURLs(selectedItems)
            guard !urls.isEmpty else { return event }
            BatchQuickLooker.quicklook(urls)
            return nil
        }
    }

    private func removeSpaceMonitor() {
        if let m = spaceMonitor { NSEvent.removeMonitor(m); spaceMonitor = nil }
    }

    private func applyAdjust(_ ids: [String]?) {
        let affected = affectedIDs(scope: ids)
        guard !affected.isEmpty else { showAdjust = false; return }
        var params = adjustForm.toBatchParams()
        // The form has no control for aggressive mode, so preserve whatever the batch was started with
        // (e.g. CLI --aggressive) instead of silently dropping it on re-run.
        params.aggressive = manager.params.aggressive
        manager.reapply(params: params, toSelection: affected)
        showAdjust = false
    }

    private func toggleAdjust() {
        if !showAdjust { adjustForm.seed(from: manager.params) }
        showAdjust.toggle()
    }

    private func affectedIDs(scope ids: [String]?) -> [String] {
        let types = changedTypes
        guard !types.isEmpty else { return [] }
        let scopeSet = ids.map(Set.init)
        return manager.items.filter { item in
            guard let k = batchTypeKey(item.type), types.contains(k) else { return false }
            return scopeSet?.contains(item.id) ?? true
        }.map(\.id)
    }

}

// MARK: - Results table (extracted so adjust-panel slider changes don't re-render/re-sort it)

private struct BatchResultsTable: View {
    @ObservedObject var manager: BatchManager
    @Binding var selection: Set<BatchItem.ID>

    var body: some View {
        Table(sortedItems, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.sortRank) { BatchStatusCell(item: $0) }.width(40)
            TableColumn("Name", value: \.name) { Text($0.name).lineLimit(1).truncationMode(.middle).help($0.source.string) }
            TableColumn("Format", value: \.formatKey) { item in
                Text(formatText(item)).foregroundStyle(item.newFormat != nil && item.newFormat != item.oldFormat ? .primary : .secondary)
            }.width(min: 90, ideal: 120)
            TableColumn("Size", value: \.sizeKey) { item in
                Text(sizeText(item)).monospacedDigit().foregroundStyle(item.status == .done && item.newBytes > 0 ? .primary : .secondary)
            }.width(min: 120, ideal: 160)
            TableColumn("Saved", value: \.savedKey) { item in batchSavedView(item) }.width(70)
            TableColumn("Details", value: \.detailKey) { item in
                Text(detailText(item)).monospacedDigit().foregroundStyle(item.status == .failed ? Color.orange : .secondary).lineLimit(1)
            }.width(min: 110, ideal: 170)
        }
        .contextMenu(forSelectionType: BatchItem.ID.self) { ids in
            let items = manager.items.filter { ids.contains($0.id) }
            Button("Quick Look") { BatchQuickLooker.quicklook(batchResultURLs(items)) }
                .disabled(items.isEmpty)
            Button("Show in Finder") { batchReveal(items) }
                .disabled(items.isEmpty)
            Button("Copy") { batchCopyFiles(items) }
                .disabled(items.isEmpty)
            if ids.count == 1, let id = ids.first, let item = items.first {
                Divider()
                Button("Compare before / after") { manager.compareItem(id: id) }
                    .disabled(!manager.canReapply || item.status != .done)
            }
            if manager.canReapply {
                Divider()
                Button("Restore original\(ids.count > 1 ? "s" : "")") { manager.restoreFromBackup(toSelection: Array(ids)) }
                    .disabled(manager.isRunning || manager.isRestoring)
            }
        } primaryAction: { ids in
            BatchQuickLooker.quicklook(batchResultURLs(manager.items.filter { ids.contains($0.id) }))
        }
    }

    @State private var sortOrder = [KeyPathComparator(\BatchItem.sortRank, order: .forward)]

    private var sortedItems: [BatchItem] {
        manager.items.sorted(using: sortOrder)
    }

}

@ViewBuilder private func batchSavedView(_ item: BatchItem) -> some View {
    if item.status == .done, let pct = savedPercent(old: item.oldBytes, new: item.newBytes) {
        Text(pct > 0 ? "−\(pct)%" : (pct < 0 ? "+\(-pct)%" : "0%"))
            .monospacedDigit()
            .foregroundStyle(pct > 0 ? Color.green : (pct < 0 ? Color.red : Color.secondary))
    } else {
        Text("")
    }
}

private func batchResultURLs(_ items: [BatchItem]) -> [URL] {
    items.map { ($0.resultPath ?? $0.source).url }.filter { FileManager.default.fileExists(atPath: $0.path) }
}

private func batchReveal(_ items: [BatchItem]) {
    let urls = batchResultURLs(items)
    if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
}

private func batchCopyFiles(_ items: [BatchItem]) {
    let urls = batchResultURLs(items)
    guard !urls.isEmpty else { return }
    let pb = NSPasteboard.general
    let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    pb.clearContents()
    pb.declareTypes([type], owner: nil)
    pb.setPropertyList(urls.map(\.path), forType: type)
}

// MARK: - Status cell

struct BatchStatusCell: View {
    let item: BatchItem

    var body: some View {
        switch item.status {
        case .running, .copying:
            if item.progressFraction > 0 {
                ProgressView(value: item.progressFraction).progressViewStyle(.linear).frame(width: 30)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done: SwiftUI.Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: SwiftUI.Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .queued: SwiftUI.Image(systemName: "clock").foregroundStyle(.tertiary)
        case .skipped: SwiftUI.Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Cell text

private func formatText(_ item: BatchItem) -> String {
    let old = item.oldFormat ?? ""
    if let new = item.newFormat, !new.isEmpty, new != old { return "\(old) → \(new)" }
    return old
}

private func sizeText(_ item: BatchItem) -> String {
    if item.status == .done, item.newBytes > 0 { return "\(humanBytes(item.oldBytes)) → \(humanBytes(item.newBytes))" }
    return humanBytes(item.oldBytes)
}

private func detailText(_ item: BatchItem) -> String {
    if item.status == .failed { return item.error ?? "Failed" }
    switch item.type {
    case .pdf:
        if let o = item.oldDPI, let n = item.newDPI, o != n { return "\(o) → \(n) DPI" }
        if let dpi = item.newDPI ?? item.oldDPI { return "\(dpi) DPI" }
        return ""
    case .audio:
        if let o = item.oldBitrate, let n = item.newBitrate, o != n { return "\(o) → \(n) kbps" }
        if let br = item.newBitrate ?? item.oldBitrate { return "\(br) kbps" }
        return ""
    default:
        let o = dimensions(item.oldSize), n = dimensions(item.newSize)
        if let o, let n, o != n { return "\(o) → \(n)" }
        return n ?? o ?? ""
    }
}

// MARK: - Failures sheet

struct BatchFailuresSheet: View {
    @ObservedObject var manager: BatchManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(failures.count) file\(failures.count == 1 ? "" : "s") failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            List(failures) { item in
                DisclosureGroup {
                    if let log = item.errorLog {
                        ScrollView(.horizontal) {
                            Text(log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .padding(8)
                        }
                        .frame(maxHeight: 220)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text("No tool output captured for this failure.").font(.callout).foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).fontWeight(.medium)
                        Text(item.error ?? "Unknown error").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack {
                Button("Copy") { copyFailures() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    @Environment(\.dismiss) private var dismiss

    private var failures: [BatchItem] {
        manager.items.filter { $0.status == .failed }
    }

    private func copyFailures() {
        let text = failures.map { item in
            var entry = "## \(item.source.string)\n\(item.error ?? "Unknown error")"
            if let log = item.errorLog { entry += "\n\n\(log)" }
            return entry
        }.joined(separator: "\n\n———\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
