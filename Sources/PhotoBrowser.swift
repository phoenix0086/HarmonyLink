import AppKit
import SwiftUI

enum PhoneGallery {
    static let root = "/mnt/data/100/media_fuse/Photo"

    static func entries(in path: String, device: Device) async throws -> [String] {
        guard let hdc = Tools.hdc else { throw PhotoExportError(message: "找不到华为调试工具。") }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Only the album picker needs directory markers. The photo list is sorted on the Mac.
        let flags = path == root ? "-1p" : "-1f"
        let response = await Tools.run(hdc, ["-t", device.id, "shell", "ls " + flags + " " + quoted], timeout: 45)
        try Task.checkCancellation()
        if response.code == -1 {
            throw PhotoExportError(message: "读取相册超时。可先切换相册，或用「按文件名查找」导出。")
        }
        guard !response.failed, !response.output.hasPrefix("ls:") else {
            throw PhotoExportError(message: "读取图库失败。请保持手机解锁并授权 USB 调试。")
        }
        return response.output.split(whereSeparator: \.isNewline).map(String.init)
    }

    static func receive(_ name: String, album: String, device: Device, into directory: URL) async throws -> URL {
        guard let hdc = Tools.hdc else { throw PhotoExportError(message: "找不到华为调试工具。") }
        let remote = root + "/" + album + "/" + name
        let staged = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        let file = staged.appendingPathComponent(name)
        do {
            let result = await Tools.run(hdc, ["-t", device.id, "file", "recv", remote, file.path], timeout: 180)
            try Task.checkCancellation()
            guard !result.failed, result.output.localizedCaseInsensitiveContains("FileTransfer finish"),
                  let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 else {
                throw PhotoExportError(message: "读取原图失败。请检查照片是否已下载到手机。")
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}

@MainActor
private final class PhotoBrowserModel: ObservableObject {
    let device: Device
    @Published var choosingPhotos = false
    @Published var searchByName = false
    @Published var albums: [String] = []
    @Published var album = ""
    @Published var photos: [String] = []
    @Published var selection: Set<String> = []
    @Published var filter = ""
    @Published var preview: NSImage?
    @Published var previewing = false
    @Published var loading = true
    @Published var exportTask: Task<Void, Never>?
    @Published var destination: URL?
    @Published var message: String?

    init(device: Device) { self.device = device }

    var visiblePhotos: [String] {
        filter.isEmpty ? photos : photos.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    func loadAlbums() async {
        do {
            albums = try await PhoneGallery.entries(in: PhoneGallery.root, device: device)
                .filter { $0.hasSuffix("/") }
                .map { String($0.dropLast()) }
                .filter { !$0.hasPrefix(".") && !$0.contains("/") }
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
        if album.isEmpty { loading = false }
    }

    func loadPhotos(_ current: String) async {
        selection = []
        photos = []
        preview = nil
        filter = ""
        guard !current.isEmpty else { loading = false; return }
        message = nil
        loading = true
        do {
            let names = try await PhoneGallery.entries(in: PhoneGallery.root + "/" + current, device: device)
            guard !Task.isCancelled, album == current else { return }
            photos = Array(Set(names.filter { PhonePhotoExport.imageType(for: $0) != nil }))
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
        if !Task.isCancelled, album == current { loading = false }
    }

    var previewName: String? {
        guard exportTask == nil, selection.count == 1 else { return nil }
        return selection.first
    }

    func loadPreview(_ name: String?) async {
        preview = nil
        previewing = false
        guard let name else { return }
        let current = album
        previewing = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await Task.sleep(for: .milliseconds(250))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let file = try await PhoneGallery.receive(name, album: current, device: device, into: directory)
            if !Task.isCancelled, album == current, selection == [name] {
                preview = NSImage(data: try Data(contentsOf: file))
            }
        } catch {
            // A preview failure should still allow an original-file export.
        }
        if !Task.isCancelled, album == current, selection == [name] { previewing = false }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "选择 Mac 上的保存文件夹"
        panel.directoryURL = destination ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.prompt = "保存到此文件夹"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let folder = panel.url else { return }
            self.destination = folder
        }
    }

    func exportSelected() {
        guard exportTask == nil, let destination else { return }
        exportTask = Task { await self.export(to: destination) }
    }

    private func export(to folder: URL) async {
        let names = photos.filter { selection.contains($0) }
        let current = album
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
            exportTask = nil
        }
        var count = 0
        var failures = 0
        var firstError: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            for (index, name) in names.enumerated() {
                try Task.checkCancellation()
                message = "正在下载 \(index + 1) / \(names.count)…"
                do {
                    let file = try await PhoneGallery.receive(name, album: current, device: device, into: directory)
                    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                    try Task.checkCancellation()
                    let stem = file.deletingPathExtension().lastPathComponent
                    var destination = folder.appendingPathComponent(name)
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: destination.path) {
                        destination = folder.appendingPathComponent("\(stem) \(suffix)").appendingPathExtension(file.pathExtension)
                        suffix += 1
                    }
                    try FileManager.default.copyItem(at: file, to: destination)
                    count += 1
                    selection.remove(name)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures += 1
                    if firstError == nil { firstError = "\(name)：\(error.localizedDescription)" }
                }
            }
            if let firstError {
                message = "已下载 \(count) 张，失败 \(failures) 张，失败项仍保留选中。\n\(firstError)"
            } else {
                message = "已下载 \(count) 张原图。"
            }
        } catch is CancellationError {
            message = "已取消，已下载 \(count) 张。"
        } catch {
            message = "无法开始下载：\(error.localizedDescription)"
        }
    }
}

struct PhotoBrowserSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PhotoBrowserModel

    init(device: Device) {
        self.device = device
        _model = StateObject(wrappedValue: PhotoBrowserModel(device: device))
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("导出方式", selection: $model.searchByName) {
                Text("导出到 Mac").tag(false)
                Text("按文件名查找").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.searchByName {
                PhotoExportSheet(device: device)
            } else {
                destination
            }
        }
        .padding(18)
        .frame(width: 350)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { model.exportTask?.cancel() }
        .sheet(isPresented: $model.choosingPhotos) {
            PhotoSelectionSheet(model: model)
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: model.chooseFolder) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 32)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mac 保存位置").font(.headline)
                            Text(model.destination?.path ?? "选择文件夹…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mac 保存位置")
                .accessibilityValue(model.destination?.path ?? "未选择")
                .help(model.destination?.path ?? "选择 Mac 上的文件夹")

                Divider().padding(.leading, 12)
                HStack {
                    Button("选择手机照片…") { model.choosingPhotos = true }
                    Spacer()
                    Text("已选 \(model.selection.count) 张")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator.opacity(0.6))
                    .allowsHitTesting(false)
            }
            .disabled(model.exportTask != nil)

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出到 Mac", action: model.exportSelected)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.destination == nil || model.selection.isEmpty || model.exportTask != nil)
            }
        }
    }
}

private struct PhotoSelectionSheet: View {
    @ObservedObject var model: PhotoBrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("相册", selection: $model.album) {
                    Text("选择相册").tag("")
                    ForEach(model.albums, id: \.self) { Text($0).tag($0) }
                }
                TextField("搜索文件名", text: $model.filter)
            }

            HStack(spacing: 10) {
                List(model.visiblePhotos, id: \.self, selection: $model.selection) { name in
                    Label(name, systemImage: "photo").lineLimit(1).tag(name)
                }
                .accessibilityLabel("手机照片列表")
                .frame(minWidth: 220)
                .overlay {
                    if model.loading { ProgressView() }
                    else if model.album.isEmpty { Text("先选择相册").foregroundStyle(.secondary) }
                    else if model.visiblePhotos.isEmpty { Text("没有可显示的照片").foregroundStyle(.secondary) }
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    if let image = model.preview {
                        Image(nsImage: image).resizable().scaledToFit().padding(5)
                    } else if model.previewing {
                        ProgressView()
                    } else {
                        Text("单选可预览").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 210)
            }
            Text(model.message ?? "按住 ⌘ 多选手机照片。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text("已选 \(model.selection.count) 张").foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 430)
        .task { await model.loadAlbums() }
        .task(id: model.album) { await model.loadPhotos(model.album) }
        .task(id: model.previewName) { [name = model.previewName] in await model.loadPreview(name) }
    }
}
