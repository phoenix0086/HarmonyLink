import AppKit
import Foundation
import Darwin

struct Device: Identifiable, Equatable {
    let id: String
    var wireless: Bool { id.contains(":") }
    var title: String { "\(wireless ? "Wi‑Fi" : "USB") · \(id)" }
}

enum WirelessPictureQuality: Int, CaseIterable, Identifiable {
    case original = 1
    case clear = 2
    case smooth = 4

    var id: Self { self }
    var title: String {
        switch self {
        case .original: "原始分辨率"
        case .clear: "高清"
        case .smooth: "流畅"
        }
    }

    var encoderBitRate: Int {
        switch self {
        case .original: 10
        case .clear: 5
        case .smooth: 2
        }
    }
}

struct ToolResult {
    let output: String
    let code: Int32

    var message: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    var failed: Bool {
        code != 0 || message.range(of: #"(?i)(?:\[fail\]|\bfailed\b|^error:)"#,
                                   options: .regularExpression) != nil
    }
}

enum Tools {
    static var resources: URL { Bundle.main.resourceURL! }

    static var java: String? {
        executable([
            resources.appendingPathComponent("Java/bin/java").path,
            "/opt/homebrew/opt/openjdk/bin/java",
            "/usr/bin/java"
        ])
    }

    static var hdc: String? {
        executable([
            resources.appendingPathComponent("HDC/hdc").path,
            "/Applications/Command Line Tools/sdk/default/openharmony/toolchains/hdc",
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
            "/opt/homebrew/bin/hdc", "/usr/local/bin/hdc"
        ])
    }

    private static func executable(_ paths: [String]) -> String? {
        paths.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static func run(_ path: String, _ arguments: [String], timeout: Double = 12) async -> ToolResult {
        let worker = Task.detached(priority: .userInitiated) {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: output.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: output) else {
                return ToolResult(output: "无法创建临时诊断文件", code: -1)
            }
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: output)
            }
            guard !Task.isCancelled else { return ToolResult(output: "已取消", code: -1) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = handle
            do {
                try process.run()
            } catch {
                return ToolResult(output: error.localizedDescription, code: -1)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while process.isRunning {
                if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    return ToolResult(output: Task.isCancelled ? "已取消" : "华为调试工具响应超时", code: -1)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return ToolResult(output: (try? String(contentsOf: output, encoding: .utf8)) ?? "",
                              code: process.terminationStatus)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func wirelessAddress(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = value.lastIndex(of: ":"), let port = UInt16(value[value.index(after: split)...]),
              port > 0 else { return nil }
        let host = String(value[..<split])
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return "\(host):\(port)" }
        return nil
    }
}

enum PhoneEditKey: Int {
    case backspace = 2055, delete = 2071, enter = 2054, tab = 2049
    case up = 2012, down = 2013, left = 2014, right = 2015
    case home = 2081, end = 2082

    init?(command: Selector) {
        switch NSStringFromSelector(command) {
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:": self = .backspace
        case "deleteForward:": self = .delete
        case "insertNewline:", "insertLineBreak:": self = .enter
        case "insertTab:": self = .tab
        case "moveUp:": self = .up
        case "moveDown:": self = .down
        case "moveLeft:": self = .left
        case "moveRight:": self = .right
        case "moveToBeginningOfLine:": self = .home
        case "moveToEndOfLine:": self = .end
        default: return nil
        }
    }
}

private enum PhoneInput {
    case text(String)
    case key(PhoneEditKey)
}

struct BridgeCommandQueue {
    struct Command {
        let text: String
        let replaceableMove: Bool
    }

    private var pending = [Command]()

    mutating func push(_ text: String, replaceableMove: Bool) {
        let command = Command(text: text, replaceableMove: replaceableMove)
        if replaceableMove, pending.last?.replaceableMove == true {
            pending[pending.count - 1] = command
        } else {
            pending.append(command)
        }
    }

    mutating func pop() -> String? {
        pending.isEmpty ? nil : pending.removeFirst().text
    }
}

@MainActor
final class MirrorConnection: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published var selected = ""
    @Published var wifi = false
    @Published var autoConnectUSB = UserDefaults.standard.object(forKey: "autoConnectUSB") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnectUSB, forKey: "autoConnectUSB") }
    }
    @Published var showControls = false
    @Published var showPhotoExport = false
    @Published var zoomRequest: MirrorZoomRequest?
    @Published private(set) var videoAspect: CGFloat = 9.0 / 19.5
    @Published private(set) var videoDimensions = CGSize.zero
    @Published private(set) var wirelessQuality =
        WirelessPictureQuality(rawValue: UserDefaults.standard.integer(forKey: "wirelessQuality")) ?? .clear
    @Published private(set) var firstFrameSeconds: Double?
    @Published var address = UserDefaults.standard.string(forKey: "wirelessAddress") ?? ""
    @Published private(set) var active: Device?
    @Published private(set) var picture = false
    @Published private(set) var refreshing = false
    @Published private(set) var status = "连接手机"
    @Published private(set) var detail = "手机解锁并允许调试后，就可以开始投屏。"

    @Published private(set) var fileHover = false
    @Published private(set) var transferStatus: String?
    @Published private(set) var transferring = false
    private var transferTask: Task<Void, Never>?
    private var transferMessageTimer: Task<Void, Never>?

    let video = MirrorVideo(frame: .zero)
    private var process: Process?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var outbound: AsyncStream<Void>.Continuation?
    private var bridgeCommands = BridgeCommandQueue()
    private var startupTimer: Task<Void, Never>?
    private var startupOutput = ""
    private var id = UUID()
    private var startedAt = ContinuousClock.now
    private var scanning = false
    private var skippedUSB: Set<String> = []
    private var streamRequestedSize = false
    private var lastMove: ContinuousClock.Instant?
    private var lastTouchPoint: CGPoint?
    private var inputQueue = [PhoneInput]()
    private var inputTask: Task<Void, Never>?
    private var galleryCheck: Task<Void, Never>?
    private var galleryMonitor: Task<Void, Never>?
    private var galleryRevision = 0
    private let galleryTransfers = GalleryTransferQueue()

    init() {
        video.onTouch = { [weak self] phase, x, y in
            guard let self else { return }
            let now = ContinuousClock.now
            let point = CGPoint(x: x, y: y)
            let wireless = active?.wireless == true
            let interval = Duration.milliseconds(wireless ? 24 : 12)
            let event = phase == "dragRelease" ? "move" : phase
            if phase == "move" {
                guard point != lastTouchPoint,
                      lastMove.map({ now - $0 >= interval }) ?? true else { return }
            }
            if wireless, event == "up", let previous = lastTouchPoint, previous != point {
                send(["type": "touch", "event": "move", "x": x, "y": y])
            }
            lastMove = event == "move" ? now : nil
            lastTouchPoint = event == "up" ? nil : point
            send(["type": "touch", "event": event, "x": x, "y": y], replaceableMove: phase == "move")
        }
        video.onBack = { [weak self] in self?.key("back") }
        video.canDropFiles = { [weak self] in self?.canSendFiles == true }
        video.onFileHover = { [weak self] in self?.fileHover = $0 }
        video.onFiles = { [weak self] in self?.sendFiles($0) == true }
        video.onText = { [weak self] in self?.enqueueInput(.text($0)) }
        video.onEditKey = { [weak self] in self?.enqueueInput(.key($0)) }
        video.onCheckGallery = { [weak self] in self?.checkGallery() }
        video.onSelectGalleryPhoto = { [weak self] photo, apply in
            guard let self, self.picture, let device = self.active, let hdc = Tools.hdc else {
                apply(nil)
                return
            }
            let attempt = self.id
            Task { [weak self] in
                let current = await GalleryPhoto.current(hdc: hdc, device: device)
                guard let self, self.id == attempt else { return }
                let matches = current?.uri == photo.uri
                if !matches { self.showTransferStatus("当前照片已变化，请重新选择。", ongoing: false) }
                apply(matches ? current : nil)
            }
        }
        video.onDragPhotos = { [weak self] photos, verifyCurrent in
            guard let self, self.picture, let device = self.active, let hdc = Tools.hdc else { return [] }
            let attempt = self.id
            var used = Set<String>()
            return photos.map { photo in
                let base = (photo.name as NSString).deletingPathExtension
                let ext = (photo.name as NSString).pathExtension
                var name = photo.name
                var suffix = 2
                while !used.insert(name.lowercased()).inserted {
                    name = "\(base) \(suffix).\(ext)"
                    suffix += 1
                }
                return GalleryPhotoPromise(photo: photo, filename: name, verifyCurrent: verifyCurrent,
                                           hdc: hdc, device: device, transfers: self.galleryTransfers,
                                           isCurrentSession: { [weak self] in self?.id == attempt }) { [weak self] message, ongoing in
                    guard let self, self.id == attempt else { return }
                    self.showTransferStatus(message, ongoing: ongoing)
                }
            }
        }
    }

    private func showTransferStatus(_ message: String, ongoing: Bool) {
        guard !transferring else { return }
        transferMessageTimer?.cancel()
        transferStatus = message
        if !ongoing {
            transferMessageTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { self?.transferStatus = nil }
            }
        }
    }

    private func monitorGallery() {
        checkGallery()
        let attempt = id
        galleryMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.id == attempt, !Task.isCancelled else { return }
                guard self.galleryCheck == nil, !self.transferring, self.video.window?.isKeyWindow == true,
                      self.lastTouchPoint == nil else { continue }
                self.checkGallery()
            }
        }
    }

    private func checkGallery() {
        guard picture, let device = active, let hdc = Tools.hdc else { return }
        galleryRevision &+= 1
        guard galleryCheck == nil else { return }
        let attempt = id
        galleryCheck = Task { [weak self] in
            while let self, self.id == attempt, !Task.isCancelled {
                let revision = self.galleryRevision
                try? await Task.sleep(for: .milliseconds(device.wireless ? 260 : 180))
                guard self.id == attempt, !Task.isCancelled else { return }
                guard self.galleryRevision == revision else { continue }
                let photo = await GalleryPhoto.current(hdc: hdc, device: device)
                guard self.id == attempt, !Task.isCancelled else { return }
                guard self.galleryRevision == revision else { continue }
                self.galleryCheck = nil
                if self.video.galleryPhoto != photo { self.video.galleryPhoto = photo }
                return
            }
        }
    }

    var canSendFiles: Bool { picture && active != nil && !transferring }

    func chooseFiles() {
        guard canSendFiles, let window = NSApp.keyWindow else { return }
        let attempt = id
        showControls = false
        let panel = NSOpenPanel()
        panel.title = "发送文件到手机"
        panel.prompt = "发送"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, self.id == attempt else { return }
            _ = self.sendFiles(panel.urls)
        }
    }

    @discardableResult
    func sendFiles(_ files: [URL]) -> Bool {
        guard canSendFiles, !files.isEmpty, let device = active, let hdc = Tools.hdc else { return false }
        let attempt = id
        transferMessageTimer?.cancel()
        fileHover = false
        transferring = true
        transferStatus = "正在发送文件…"
        transferTask = Task { [weak self] in
            guard let self else { return }
            var sent = 0
            var lastError: String?
            for (index, file) in files.enumerated() {
                guard self.id == attempt, !Task.isCancelled else { return }
                self.transferStatus = "正在发送 \(index + 1)/\(files.count) · \(file.lastPathComponent)"
                if let error = await PhoneFileTransfer.send(file, using: hdc, to: device) {
                    lastError = error
                } else {
                    sent += 1
                }
            }
            guard self.id == attempt, !Task.isCancelled else { return }
            self.transferring = false
            self.transferTask = nil
            self.transferStatus = switch sent {
            case files.count: "已发送 \(sent) 个文件 · \(PhoneFileTransfer.displayFolder)"
            case 0: lastError ?? "发送失败。"
            default: "已发送 \(sent)/\(files.count) 个文件 · \(PhoneFileTransfer.displayFolder)"
            }
            self.transferMessageTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(sent == 0 ? 14 : 6))
                if !Task.isCancelled { self?.transferStatus = nil }
            }
        }
        return true
    }

    func refresh(report: Bool = true) async {
        guard !scanning, !refreshing, active == nil else { return }
        scanning = true
        refreshing = report
        let attempt = id
        let listed = await updateDevices(report: report)
        guard id == attempt else { return }
        scanning = false
        refreshing = false
        guard listed, active == nil, !wifi, autoConnectUSB, !Task.isCancelled else { return }
        let wired = devices.filter { !$0.wireless }
        if wired.count == 1, let device = wired.first, !skippedUSB.contains(device.id) {
            connect(device)
        }
    }

    private func updateDevices(report: Bool) async -> Bool {
        guard let hdc = Tools.hdc else {
            status = "缺少华为调试工具"
            detail = "安装华为 Command Line Tools 或 DevEco Studio 后再刷新。"
            return false
        }
        let attempt = id
        let result = await Tools.run(hdc, ["list", "targets"])
        guard id == attempt, !Task.isCancelled, active == nil else { return false }
        if result.failed {
            if report || devices.isEmpty {
                status = "暂时无法读取设备"
                detail = result.message.isEmpty ? "点击「刷新」重试。" : result.message
            }
            return false
        }
        let found = result.output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                line.range(of: #"^(?:[A-Za-z0-9_-]{4,}|(?:\d{1,3}\.){3}\d{1,3}:\d+)$"#,
                           options: .regularExpression) != nil
            }
            .map(Device.init)
        let changed = devices != found
        if changed { devices = found }
        skippedUSB.formIntersection(found.map(\.id))
        if !found.contains(where: { $0.id == selected && !$0.wireless }) {
            selected = found.first(where: { !$0.wireless })?.id ?? ""
        }
        if report || (changed && !wifi && !refreshing) {
            let hasUSB = found.contains { !$0.wireless }
            status = hasUSB ? "检测到 USB 设备" : "等待设备"
            detail = hasUSB ? "可以开始投屏。" : "用数据线连接并解锁手机，在手机上允许 USB 调试。"
        }
        return true
    }

    func connectWireless() async {
        guard active == nil, !scanning, !refreshing, let hdc = Tools.hdc else { return }
        guard let endpoint = Tools.wirelessAddress(address) else {
            status = "检查无线地址"
            detail = "填写手机无线调试页面显示的 IPv4 地址和端口。"
            return
        }
        refreshing = true
        status = "正在连接 Wi‑Fi"
        detail = "如手机显示调试授权提示，请在手机上允许。"
        let attempt = id
        let result = await Tools.run(hdc, ["tconn", endpoint], timeout: 18)
        guard id == attempt else { return }
        let listed = await updateDevices(report: false)
        guard id == attempt else { return }
        refreshing = false
        guard listed, let device = devices.first(where: { $0.id == endpoint }) else {
            status = "Wi‑Fi 连接失败"
            let response = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = response.isEmpty ? "确认两台设备在同一网络，并核对手机显示的端口。" : response
            return
        }
        address = endpoint
        UserDefaults.standard.set(endpoint, forKey: "wirelessAddress")
        connect(device)
    }

    func connectSelected() {
        guard let device = devices.first(where: { $0.id == selected }) else { return }
        guard !scanning else { return }
        connect(device)
    }

    func selectWirelessQuality(_ quality: WirelessPictureQuality) {
        guard wirelessQuality != quality, !refreshing, !transferring else { return }
        wirelessQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: "wirelessQuality")
        guard active?.wireless == true else { return }
        let previous = process
        stop()
        status = "正在切换 Wi‑Fi 画质"
        refreshing = true
        let attempt = id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            let deadline = ContinuousClock.now + .seconds(4)
            while previous?.isRunning == true, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.id == attempt else { return }
            self.refreshing = false
            guard previous?.isRunning != true else {
                self.status = "画质切换未完成"
                self.detail = "上一次投屏仍在关闭，请稍后重新连接。"
                return
            }
            await self.connectWireless()
        }
    }

    private func connect(_ device: Device) {
        guard active == nil, !refreshing else { return }
        guard let hdc = Tools.hdc, let java = Tools.java else {
            status = "投屏组件不完整"
            detail = "需要华为调试工具和 Java。"
            return
        }
        let bridge = Tools.resources.appendingPathComponent("Bridge")
        let output = Pipe()
        let proc = Process()
        let attempt = UUID()
        id = attempt
        startedAt = .now
        firstFrameSeconds = nil
        streamRequestedSize = false
        active = device
        picture = false
        status = "正在连接"
        detail = "保持手机解锁，等待投屏启动。"
        startupOutput = ""
        video.reset()
        proc.executableURL = URL(fileURLWithPath: java)
        proc.arguments = [
            "-cp", bridge.appendingPathComponent("hosScrcpy-1.0.18-beta.jar").path + ":" + bridge.appendingPathComponent("out").path,
            "Main", "--sn", device.id, "--hdc", hdc, "--port", "0",
            "--scale", device.wireless ? String(wirelessQuality.rawValue) : "2",
            "--frame-rate", device.wireless ? "30" : "60",
            // The bridge's SDK takes a number of 2^20 bits/s, or 0 to keep the SDK default.
            "--bit-rate", device.wireless ? String(wirelessQuality.encoderBitRate) : "0",
            "--ifr", "2000", "--idle-exit", "30"
        ]
        proc.standardOutput = output
        proc.standardError = output
        proc.standardInput = FileHandle.nullDevice
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        process = proc
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.readStartup(data, attempt: attempt) }
        }
        proc.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                guard let self, self.id == attempt else { return }
                self.fail("投屏进程已退出", "投屏组件退出（\(code)）。确认手机已解锁并允许调试。")
            }
        }
        do {
            try proc.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            fail("无法启动投屏", error.localizedDescription)
            return
        }
        startupTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(22))
            guard !Task.isCancelled, let self, self.id == attempt, !self.picture else { return }
            if self.socket == nil {
                self.fail("连接超时", "请确认手机仍已授权调试，再重新连接。")
            } else {
                self.detail = "还在等待第一帧。在手机上滑动一下屏幕，或断开后重试。"
                try? await Task.sleep(for: .seconds(18))
                guard !Task.isCancelled, self.id == attempt, !self.picture else { return }
                self.fail("等待画面超时", "请保持手机解锁，再连接投屏。")
            }
        }
    }

    private func readStartup(_ data: Data, attempt: UUID) {
        guard id == attempt, socket == nil else { return }
        startupOutput += String(decoding: data, as: UTF8.self)
        if startupOutput.count > 16000 { startupOutput = String(startupOutput.suffix(12000)) }
        let expression = #""ready"\s*:\s*true\s*,\s*"port"\s*:\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: startupOutput, range: NSRange(startupOutput.startIndex..., in: startupOutput)),
              let range = Range(match.range(at: 1), in: startupOutput),
              let port = UInt16(startupOutput[range]), port > 0,
              let url = URL(string: "ws://127.0.0.1:\(port)/") else { return }
        openSocket(url, attempt: attempt)
    }

    private func openSocket(_ url: URL, attempt: UUID) {
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.maximumMessageSize = 8 * 1024 * 1024
        socket = ws
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        outbound = stream.continuation
        ws.resume()
        sender = Task { [weak self] in
            do {
                for await _ in stream.stream {
                    while let self, self.id == attempt, !Task.isCancelled,
                          let command = self.bridgeCommands.pop() {
                        try await ws.send(.string(command))
                    }
                }
            } catch {
                guard let self, self.id == attempt, !Task.isCancelled else { return }
                self.fail("投屏连接中断", error.localizedDescription)
            }
        }
        send(["type": "screen", "mode": "video"])
        status = "等待手机画面"
        detail = "如果画面没有出现，在手机屏幕上滑动一下。"
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard let self, self.id == attempt else { return }
                    switch message {
                    case .data(let data):
                        if !self.streamRequestedSize {
                            self.streamRequestedSize = true
                            self.send(["type": "size"])
                        }
                        let rendered = self.video.consume(data)
                        if self.video.dimensions != self.videoDimensions {
                            self.videoDimensions = self.video.dimensions
                        }
                        if let aspect = self.video.aspectRatio, aspect != self.videoAspect {
                            self.videoAspect = aspect
                        }
                        if rendered, !self.picture {
                            self.startupTimer?.cancel()
                            let elapsed = (ContinuousClock.now - self.startedAt).components
                            self.firstFrameSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                            self.picture = true
                            self.monitorGallery()
                            self.status = "已连接 · " + (self.active?.wireless == true ? "Wi‑Fi" : "USB")
                            self.detail = "点手机输入框后直接打字。右键返回上一级。"
                        }
                    case .string(let text):
                        self.receiveStatus(text)
                    @unknown default: break
                    }
                }
            } catch {
                guard let self, self.id == attempt, !Task.isCancelled else { return }
                self.fail("投屏连接中断", error.localizedDescription)
            }
        }
    }

    private func receiveStatus(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if json["msg"] as? String == "stream ready: video", !streamRequestedSize {
            streamRequestedSize = true
            send(["type": "size"])
        } else if json["msg"] as? String == "size", let data = json["data"] as? String {
            let parts = data.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                video.setScreen(width: parts[0], height: parts[1])
            }
        } else if json["ok"] as? Bool == false {
            detail = json["error"] as? String ?? json["msg"] as? String ?? "手机拒绝了这次操作。"
        }
    }

    private func send(_ object: [String: Any], replaceableMove: Bool = false) {
        guard let outbound, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        bridgeCommands.push(text, replaceableMove: replaceableMove)
        outbound.yield(())
    }

    func key(_ name: String) { if picture { send(["type": "key", "name": name]) } }

    private func enqueueInput(_ input: PhoneInput) {
        guard picture, let device = active, let hdc = Tools.hdc else { return }
        if case .text(let text) = input, case .text(let previous)? = inputQueue.last {
            inputQueue[inputQueue.count - 1] = .text(previous + text)
        } else {
            inputQueue.append(input)
        }
        guard inputTask == nil else { return }
        let attempt = id
        inputTask = Task { [weak self] in
            // Let the tap settle and combine consecutive keystrokes into a single HDC call.
            try? await Task.sleep(for: .milliseconds(65))
            guard let self, attempt == self.id, !Task.isCancelled else { return }
            while !self.inputQueue.isEmpty, attempt == self.id, !Task.isCancelled {
                let item = self.inputQueue.removeFirst()
                let sent: Bool
                switch item {
                case .text(let text):
                    sent = await self.sendText(text, hdc: hdc, device: device, attempt: attempt)
                case .key(let key):
                    let code = key.rawValue
                    let result = await Tools.run(hdc, ["-t", device.id, "shell",
                        "uinput -K -d \(code) -u \(code)"], timeout: 4)
                    sent = !result.failed
                }
                guard attempt == self.id, !Task.isCancelled else { return }
                if !sent { self.detail = "键盘输入发送失败。请先点选手机输入框，或尝试重新连接。" }
            }
            self.inputTask = nil
        }
    }

    private func sendText(_ text: String, hdc: String, device: Device, attempt: UUID) async -> Bool {
        guard !text.isEmpty else { return true }
        // Simple text fits in one call. Arbitrary pasted text goes through a UTF‑8 file.
        if text.range(of: #"\A[\p{L}\p{M}\p{N} .,?!:/@_+\-]{1,120}\z"#,
                      options: .regularExpression) != nil,
           text.utf16.count == text.unicodeScalars.count {
            let result = await Tools.run(hdc, ["-t", device.id, "shell",
                "uitest uiInput text '" + text + "'"], timeout: 4)
            return !result.failed
        }
        let name = "harmonylink-input-" + UUID().uuidString
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let remote = "/data/local/tmp/" + name
        defer { try? FileManager.default.removeItem(at: local) }
        do {
            try Data(text.utf8).write(to: local, options: [.atomic])
        } catch {
            return false
        }
        let upload = await Tools.run(hdc, ["-t", device.id, "file", "send", local.path, remote])
        guard !upload.failed, attempt == id, !Task.isCancelled else {
            _ = await Tools.run(hdc, ["-t", device.id, "shell", "rm -f " + remote], timeout: 3)
            return false
        }
        let substitution = "$" + "{text%.}"
        let result = await Tools.run(hdc, ["-t", device.id, "shell",
            "text=$(cat " + remote + " && printf .) && uitest uiInput text \"" + substitution +
            "\"; result=$?; rm -f " + remote + "; exit $result"])
        return !result.failed
    }

    private func fail(_ title: String, _ message: String) {
        stop()
        status = title
        detail = message
    }

    func stop() {
        if let active, !active.wireless { skippedUSB.insert(active.id) }
        id = UUID()
        scanning = false
        refreshing = false
        startupTimer?.cancel()
        transferTask?.cancel()
        transferTask = nil
        transferMessageTimer?.cancel()
        transferStatus = nil
        transferring = false
        fileHover = false
        inputTask?.cancel()
        galleryCheck?.cancel()
        galleryCheck = nil
        galleryMonitor?.cancel()
        galleryMonitor = nil
        inputTask = nil
        inputQueue.removeAll()
        lastMove = nil
        lastTouchPoint = nil
        receiver?.cancel()
        sender?.cancel()
        outbound?.finish()
        outbound = nil
        bridgeCommands = BridgeCommandQueue()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        active = nil
        picture = false
        firstFrameSeconds = nil
        showControls = false
        showPhotoExport = false
        zoomRequest = nil
        videoAspect = 9.0 / 19.5
        videoDimensions = .zero
        video.reset()
        status = "已断开"
        detail = "可以重新连接手机。"
    }
}
