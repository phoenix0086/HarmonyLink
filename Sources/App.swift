import SwiftUI

@main
struct HarmonyLinkApp: App {
    @StateObject private var connection = MirrorConnection()

    var body: some Scene {
        Window("鸿蒙投屏", id: "mirror") {
            MirrorWindow(connection: connection)
                .onDisappear { connection.stop() }
        }
        .defaultSize(width: 840, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("投屏") {
                Button("发送文件到手机…") { connection.chooseFiles() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!connection.canSendFiles)
                Button("从手机取照片…") { connection.showPhotoExport = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(connection.active == nil)
                Divider()
                Button("放大窗口") { connection.zoomRequest = MirrorZoomRequest(action: .inLarger) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(connection.active == nil)
                Button("缩小窗口") { connection.zoomRequest = MirrorZoomRequest(action: .outSmaller) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(connection.active == nil)
                Button("恢复默认大小") { connection.zoomRequest = MirrorZoomRequest(action: .fit) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(connection.active == nil)
            }
        }
    }
}

struct MirrorWindow: View {
    @ObservedObject var connection: MirrorConnection
    @Environment(\.colorScheme) private var colorScheme

    private var linked: Bool { connection.active != nil }
    private var hasPicture: Bool { connection.picture }
    private var wired: [Device] { connection.devices.filter { !$0.wireless } }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if linked {
                    stage
                } else {
                    desktop
                    ScrollView {
                        connectionPanel
                            .frame(maxWidth: 372)
                            .frame(minHeight: 374)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 28)
                    }
                    .defaultScrollAnchor(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            MirrorWindowSizing(aspect: linked ? connection.videoAspect : nil, zoomRequest: connection.zoomRequest)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { connection.key("back") } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("返回手机上一页（⌘[）")
                .disabled(!hasPicture)

                Button { connection.key("home") } label: {
                    Label("手机桌面", systemImage: "house")
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .help("回到手机桌面（⇧⌘H）")
                .disabled(!hasPicture)
            }
            if linked {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        connection.showControls.toggle()
                    } label: {
                        Label("连接详情", systemImage: "info.circle")
                    }
                    .help("查看连接详情")
                    .popover(isPresented: $connection.showControls, arrowEdge: .top) {
                        connectionDetails
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        connection.stop()
                    } label: {
                        Label("断开投屏", systemImage: "stop.circle")
                    }
                    .help("断开投屏")
                }
            }
        }
        .sheet(isPresented: $connection.showPhotoExport) {
            if let device = connection.active { PhotoExportSheet(device: device) }
        }
        .task {
            await connection.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled, !connection.wifi { await connection.refresh(report: false) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            connection.stop()
        }
    }

    private var desktop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.09), .clear],
                center: UnitPoint(x: 0.5, y: 0.13), startRadius: 20, endRadius: 480
            )
        }
        .accessibilityHidden(true)
    }

    private var connectionPanel: some View {
        VStack(spacing: 22) {
            VStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 23)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 31, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
                .shadow(color: Color.accentColor.opacity(0.22), radius: 12, y: 5)
                .accessibilityHidden(true)
                Text("连接鸿蒙设备")
                    .font(.system(size: 27, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 14) {
                Picker("连接方式", selection: $connection.wifi) {
                    Text("USB").tag(false)
                    Text("Wi‑Fi").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.large)
                .disabled(connection.refreshing)

                if connection.wifi { wirelessForm } else { usbForm }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.07), radius: 18, y: 7)

            Label(connection.status, systemImage: connection.refreshing ? "arrow.trianglehead.clockwise" : "circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .animation(.easeInOut(duration: 0.18), value: connection.wifi)
    }

    private var usbForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(connection.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !wired.isEmpty {
                Picker("USB 设备", selection: $connection.selected) {
                    if !wired.contains(where: { $0.id == connection.selected }) {
                        Text("选择设备").tag(connection.selected)
                    }
                    ForEach(wired) { device in Text(device.id).tag(device.id) }
                }
            }

            HStack(spacing: 8) {
                Button {
                    connection.connectSelected()
                } label: {
                    Text("开始投屏").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(connection.refreshing || !wired.contains(where: { $0.id == connection.selected }))

                Button {
                    Task { await connection.refresh() }
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("刷新设备")
                .disabled(connection.refreshing)
            }
            .controlSize(.large)

            Divider()
            Toggle("自动投屏已授权的单台 USB 设备", isOn: $connection.autoConnectUSB)
                .font(.callout)
        }
    }

    private var wirelessForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在手机的「开发者选项 → 无线调试」查看地址，并将两台设备连到同一个 Wi‑Fi。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("无线调试地址", text: $connection.address, prompt: Text("例如 192.168.1.20:12345"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .disabled(connection.refreshing)
                .onSubmit { Task { await connection.connectWireless() } }
            wirelessQualityPicker
            Button {
                Task { await connection.connectWireless() }
            } label: {
                Text("连接并投屏").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(connection.refreshing || connection.address.trimmingCharacters(in: .whitespaces).isEmpty)

            switch connection.status {
            case "等待设备", "检测到 USB 设备", "连接手机", "已断开":
                EmptyView()
            default:
                Text(connection.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var wirelessQualityPicker: some View {
        Picker("Wi‑Fi 画质", selection: Binding(
            get: { connection.wirelessQuality },
            set: { connection.selectWirelessQuality($0) }
        )) {
            ForEach(WirelessPictureQuality.allCases) { quality in
                Text(quality.title).tag(quality)
            }
        }
        .pickerStyle(.menu)
        .disabled(connection.refreshing || connection.transferring)
        .help("切换画质时会重新连接投屏。")
    }

    private var stage: some View {
        ZStack {
            Color.black
            VideoSurface(view: connection.video)
                .opacity(hasPicture ? 1 : 0)
                .allowsHitTesting(hasPicture)
            if !hasPicture {
                VStack(spacing: 12) {
                    ProgressView().colorScheme(.dark)
                    Text("等待手机画面")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                    Text(connection.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
        }
        .overlay {
            if connection.fileHover {
                ZStack {
                    Color.black.opacity(0.46)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    Label("松手发送到手机", systemImage: "arrow.down.to.line")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = connection.transferStatus {
                Label(message, systemImage: connection.transferring ? "arrow.up.circle" : "folder")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接详情").font(.headline)
            if let device = connection.active {
                LabeledContent("连接方式", value: device.wireless ? "Wi‑Fi" : "USB")
                LabeledContent("设备标识") {
                    Text(device.id).monospaced().textSelection(.enabled)
                }
            }
            if let seconds = connection.firstFrameSeconds {
                LabeledContent("首帧耗时") {
                    Text("\(seconds, format: .number.precision(.fractionLength(1))) 秒").monospacedDigit()
                }
            }
            let size = connection.videoDimensions
            if size.width > 0, size.height > 0 {
                LabeledContent("投屏分辨率") {
                    Text("\(Int(size.width)) × \(Int(size.height))").monospacedDigit()
                }
            }
            if connection.active?.wireless == true {
                wirelessQualityPicker
            }
            Divider()
            Button { connection.chooseFiles() } label: {
                Label("发送文件到手机…", systemImage: "square.and.arrow.up")
            }
            .disabled(!connection.canSendFiles)
            Label("文件也可直接拖入画面。", systemImage: "arrow.down.to.line")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label("点手机输入框后可直接打字。", systemImage: "keyboard")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 285)
    }
}
