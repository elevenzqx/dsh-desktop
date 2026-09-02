// DSH Desktop —— macOS 菜单栏应用（AI 网站导航工具）
// 功能: 一键启动/重启/停止 dsh web (端口 3080)、内置 AI 网站导航窗口（左侧边栏快捷入口：
//       豆包 / DeepSeek / 阿里千问 / 百度 / 腾讯元宝 / DSH 插件 / DeepSeek 费用 / 硅基流动费用，
//       可在设置中增删改排序）、动态标签页（切换不关闭、可单独关闭释放资源）、
//       执行任意命令（预设「安装 dsh 插件」示例）、查看 Web 日志。
// 行为: 启动时若 dsh web 已在运行则自动打开全屏窗口；退出时保留 dsh web 后台继续运行。
// 注: AI 导航窗口（BrowserWindowController）实现在 browser.swift。
// 技术: 原生 AppKit，仅用 Foundation/AppKit/WebKit，无第三方依赖。
import AppKit
import WebKit

let kWebPort = 3080
let kHistoryKey = "dshDesktop.commandHistory"

// MARK: - 工具路径（构建期写入 bundle，Finder 启动时 PATH 很窄无法依赖）

struct ToolPaths {
    var node: String = ""
    var dsh: String = ""
    var binDir: String = ""
}

enum ToolLocator {
    static func load() -> ToolPaths {
        // 1) bundle 内置（build.sh 写好的绝对路径）
        if let url = Bundle.main.resourceURL?.appendingPathComponent("dsh-paths.json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let node = obj["node"], let dsh = obj["dsh"] {
            if FileManager.default.isExecutableFile(atPath: node),
               FileManager.default.isExecutableFile(atPath: dsh) {
                return ToolPaths(node: node, dsh: dsh, binDir: (node as NSString).deletingLastPathComponent)
            }
        }
        // 2) 兜底：扫描 PATH 与常见目录
        var node: String?
        var dsh: String?
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        dirs += ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin",
                 "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in dirs {
            if node == nil, FileManager.default.isExecutableFile(atPath: dir + "/node") {
                node = dir + "/node"
            }
            if dsh == nil, FileManager.default.isExecutableFile(atPath: dir + "/dsh") {
                dsh = dir + "/dsh"
            }
            if node != nil && dsh != nil { break }
        }
        guard let n = node, let d = dsh else { return ToolPaths() }
        return ToolPaths(node: n, dsh: d, binDir: (n as NSString).deletingLastPathComponent)
    }
}

// MARK: - 日志（Web 服务输出 / 应用事件；优先 ~/Library/Logs，失败回退临时目录）

final class AppLog {
    static let shared = AppLog()
    private var url: URL?
    private let queue = DispatchQueue(label: "dshDesktop.applog")

    func write(_ text: String) {
        let line = "[\(Self.timestamp())] \(text)\n"
        queue.async { [weak self] in
            guard let self = self else { return }
            let u = self.resolve()
            guard let h = try? FileHandle(forWritingTo: u) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    func openInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([resolve()])
    }

    private func resolve() -> URL {
        if let url = self.url { return url }
        let fm = FileManager.default
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-desktop-web.log")
        var chosen = fallback
        if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let logs = lib.appendingPathComponent("Logs", isDirectory: true)
            if (try? fm.createDirectory(at: logs, withIntermediateDirectories: true)) != nil {
                let u = logs.appendingPathComponent("dsh-desktop-web.log")
                if fm.createFile(atPath: u.path, contents: nil) {
                    chosen = u
                }
            }
        }
        self.url = chosen
        return chosen
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - Web 服务管理（node 绝对路径拉起 dsh web；停止时按进程 + 端口兜底清理）

final class WebServerManager {
    static let shared = WebServerManager()

    private var proc: Process?
    private(set) var startedByUs = false

    func isRunning() -> Bool { pidsOnPort(kWebPort).isEmpty == false }

    func start() {
        guard !(proc?.isRunning ?? false) else { return }
        let paths = ToolLocator.load()
        guard !paths.node.isEmpty, !paths.dsh.isEmpty else {
            AppLog.shared.write("启动失败：未找到 node / dsh")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: paths.node)
        p.arguments = [paths.dsh, "web"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = paths.binDir + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            AppLog.shared.write(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        p.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.proc = nil
                self.startedByUs = false
                AppLog.shared.write("dsh web 进程已退出")
            }
        }
        do {
            try p.run()
            proc = p
            startedByUs = true
            AppLog.shared.write("已启动 dsh web（pid \(p.processIdentifier)，端口 \(kWebPort)）")
        } catch {
            AppLog.shared.write("启动 dsh web 失败：\(error.localizedDescription)")
        }
    }

    func stop(completion: ((Bool) -> Void)? = nil) {
        let tracked = proc
        proc = nil
        startedByUs = false
        if let p = tracked, p.isRunning {
            p.terminate()
            AppLog.shared.write("已向 pid \(p.processIdentifier) 发送停止信号")
        }
        DispatchQueue.global().async {
            // 等待优雅退出（最多 3 秒）
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, !self.pidsOnPort(kWebPort).isEmpty {
                Thread.sleep(forTimeInterval: 0.15)
            }
            // 兜底：仍然占用 3080 的进程强制结束（排除自己）
            let pids = self.pidsOnPort(kWebPort)
            for pid in pids where pid != getpid() {
                self.killProcess(pid, signal: 9)
                AppLog.shared.write("端口 \(kWebPort) 仍被 pid \(pid) 占用，已强制结束")
            }
            Thread.sleep(forTimeInterval: 0.4)
            let remain = self.pidsOnPort(kWebPort)
            DispatchQueue.main.async {
                if remain.isEmpty { AppLog.shared.write("dsh web 已停止") }
                completion?(remain.isEmpty)
            }
        }
    }

    /// 同步停止（应用退出时使用）：终止托管进程并按端口兜底清理，最多等待 3 秒。
    /// 在后台线程调用，避免阻塞主线程。
    func stopNow() {
        let tracked = proc
        proc = nil
        startedByUs = false
        if let p = tracked, p.isRunning {
            p.terminate()
            AppLog.shared.write("退出时向 pid \(p.processIdentifier) 发送停止信号")
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !pidsOnPort(kWebPort).isEmpty {
            Thread.sleep(forTimeInterval: 0.15)
        }
        let pids = pidsOnPort(kWebPort)
        for pid in pids where pid != getpid() {
            killProcess(pid, signal: 9)
            AppLog.shared.write("退出兜底：端口 \(kWebPort) 仍被 pid \(pid) 占用，已强制结束")
        }
        AppLog.shared.write("dsh web 已随 DSH Desktop 退出而停止")
    }

    func restart() {
        stop { [weak self] _ in
            DispatchQueue.main.async { self?.start() }
        }
    }

    func pidsOnPort(_ port: Int) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isWhitespace).compactMap { Int32(String($0)) }
    }

    private func killProcess(_ pid: Int32, signal: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/kill")
        p.arguments = ["-\(signal)", "\(pid)"]
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - 命令执行面板（弹窗：输入命令，实时显示输出）

final class CommandPanel: NSPanel {
    enum Mode { case plugin, generic }

    private var proc: Process?
    private var startTime: Date?

    private let hint = NSTextField(wrappingLabelWithString: "")
    private let cmdField = NSTextField(string: "")
    private let historyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outputView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let runButton = NSButton(title: "执行", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered,
                   defer: false)
        title = "执行命令"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 420)
        setFrameAutosaveName("dshDesktop.commandPanel")

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        contentView = bg

        buildUI()
        bindActions()
    }

    func configure(mode: Mode) {
        switch mode {
        case .plugin:
            cmdField.stringValue = ""
            cmdField.placeholderString = "dsh plugin --profile web add <npm 包名>  （可改成任意其他命令）"
            hint.stringValue = "安装 dsh 插件：填入包名后回车，或在输入框直接写任何命令（如 dsh --version）。"
        case .generic:
            cmdField.stringValue = ""
            cmdField.placeholderString = "dsh --version  或  dsh web  （任意 shell 命令）"
            hint.stringValue = "以 zsh 执行任意命令（PATH 已自动包含本机 dsh / node 目录），输出实时显示。"
        }
        statusLabel.stringValue = "就绪"
        runButton.isEnabled = true
        stopButton.isEnabled = false
        if proc?.isRunning == true { proc?.terminate(); proc = nil }
        outputView.string = ""
        rebuildHistory()
    }

    func focusCommandField() {
        makeFirstResponder(cmdField)
        cmdField.currentEditor()?.selectAll(nil)
    }

    // MARK: UI 搭建

    private func buildUI() {
        guard let content = contentView else { return }

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        historyPopup.font = .systemFont(ofSize: 12)
        historyPopup.isEnabled = false

        cmdField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        cmdField.placeholderString = "输入要执行的命令"

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        outputView.textColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        outputView.insertionPointColor = .systemGreen
        outputView.textContainerInset = NSSize(width: 10, height: 10)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        runButton.bezelStyle = .rounded
        stopButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded
        stopButton.isEnabled = false

        let views: [NSView] = [hint, cmdField, historyPopup, scroll, statusLabel,
                               stopButton, closeButton, runButton]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        outputView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = outputView

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            cmdField.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            cmdField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            cmdField.trailingAnchor.constraint(equalTo: historyPopup.leadingAnchor, constant: -8),
            cmdField.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),

            historyPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            historyPopup.centerYAnchor.constraint(equalTo: cmdField.centerYAnchor),
            historyPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            scroll.topAnchor.constraint(equalTo: cmdField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: runButton.topAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),

            runButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            runButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            closeButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),

            stopButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            stopButton.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -8),

            outputView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            outputView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            outputView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            outputView.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
    }

    private func bindActions() {
        cmdField.target = self
        cmdField.action = #selector(runPressed)
        historyPopup.target = self
        historyPopup.action = #selector(historySelected)
        runButton.target = self
        runButton.action = #selector(runPressed)
        runButton.keyEquivalent = "\r"
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
    }

    private func rebuildHistory() {
        historyPopup.menu?.removeAllItems()
        historyPopup.addItem(withTitle: "最近命令 ▾")
        let hist = UserDefaults.standard.stringArray(forKey: kHistoryKey) ?? []
        hist.forEach { historyPopup.addItem(withTitle: $0) }
        historyPopup.isEnabled = !hist.isEmpty
        historyPopup.selectItem(at: 0)
    }

    // MARK: 交互

    @objc private func historySelected() {
        let idx = historyPopup.indexOfSelectedItem
        guard idx > 0, let title = historyPopup.item(at: idx)?.title else { return }
        cmdField.stringValue = title
        historyPopup.selectItem(at: 0)
    }

    @objc private func runPressed() {
        guard proc == nil else { return }
        let cmd = cmdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { NSSound.beep(); return }

        var hist = UserDefaults.standard.stringArray(forKey: kHistoryKey) ?? []
        hist.removeAll { $0 == cmd }
        hist.insert(cmd, at: 0)
        if hist.count > 12 { hist = Array(hist.prefix(12)) }
        UserDefaults.standard.set(hist, forKey: kHistoryKey)
        rebuildHistory()

        outputView.string = "💻 $ \(cmd)\n"
        statusLabel.stringValue = "运行中…"
        runButton.isEnabled = false
        stopButton.isEnabled = true
        startTime = Date()

        let paths = ToolLocator.load()
        var env = ProcessInfo.processInfo.environment
        if !paths.binDir.isEmpty {
            env["PATH"] = paths.binDir + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendOutput(s) }
        }
        p.terminationHandler = { [weak self] p2 in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.proc = nil
                let elapsed = self.startTime.map {
                    String(format: "%.1f", Date().timeIntervalSince($0))
                } ?? "?"
                let code = p2.terminationStatus
                self.statusLabel.stringValue = "完成 · 退出码 \(code) · 耗时 \(elapsed)s"
                self.runButton.isEnabled = true
                self.stopButton.isEnabled = false
            }
        }
        do {
            try p.run()
            proc = p
        } catch {
            appendOutput("\n⚠ 启动失败：\(error.localizedDescription)\n")
            statusLabel.stringValue = "启动失败"
            runButton.isEnabled = true
            stopButton.isEnabled = false
        }
    }

    @objc private func stopPressed() {
        guard let p = proc, p.isRunning else { return }
        p.terminate()
        statusLabel.stringValue = "正在停止…"
        stopButton.isEnabled = false
    }

    @objc private func closePressed() {
        if proc?.isRunning == true { proc?.terminate(); proc = nil }
        close()
    }

    private func appendOutput(_ s: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.93, alpha: 1),
        ]
        outputView.textStorage?.append(NSAttributedString(string: s, attributes: attrs))
        outputView.scrollToEndOfDocument(nil)
    }
}

// MARK: - 简易浏览器窗口（BrowserWindowController 及其标签页/工具栏实现见 browser.swift）

// MARK: - 应用主入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var instance: AppDelegate!

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var startItem: NSMenuItem!
    private var restartItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var statusTimer: Timer?
    private var commandPanel: CommandPanel?
    private var browserWindow: BrowserWindowController?
    private var quickMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildMainMenu()
        refreshStatus()

        // 快捷栏目变更时同步重建菜单
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutStoreChanged),
                                               name: kShortcutsChanged, object: nil)

        // 需求 4：如果 dsh web 已在运行，应用启动后自动打开全屏窗口
        autoOpenIfWebRunning()
        if ProcessInfo.processInfo.environment["DSH_DESKTOP_DEBUG"] != nil {
            fputs("[selftest] app launched\n", stderr)
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.global().async {
                let pids = WebServerManager.shared.pidsOnPort(kWebPort)
                DispatchQueue.main.async {
                    self?.updateStatus(running: !pids.isEmpty, pids: pids)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        // 退出应用时保留 dsh web 后台继续运行（不再主动关闭）
        AppLog.shared.write("DSH Desktop 退出（保留 dsh web 后台）")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: 菜单

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "terminal.fill",
                                     accessibilityDescription: "DSH Desktop")
        item.button?.toolTip = "DSH Desktop"

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        startItem = makeItem("启动 dsh Web", symbol: "play.fill", key: "1", action: #selector(startWeb))
        menu.addItem(startItem)
        restartItem = makeItem("重启 dsh Web", symbol: "arrow.clockwise", key: "2", action: #selector(restartWeb))
        menu.addItem(restartItem)
        stopItem = makeItem("停止 dsh Web", symbol: "stop.fill", key: "3", action: #selector(stopWeb))
        menu.addItem(stopItem)

        menu.addItem(.separator())

        menu.addItem(makeItem("在浏览器打开页面", symbol: "safari", key: "4", action: #selector(openInBrowser)))
        menu.addItem(makeItem("打开应用窗口（全屏）", symbol: "rectangle.inset.filled", key: "5", action: #selector(openAppWindow)))
        menu.addItem(makeItem("刷新页面", symbol: "arrow.clockwise", key: "", action: #selector(refreshWebPage)))

        // 快捷页面菜单：跟随设置里配置的快捷栏目（AI 网页可直接从菜单打开）
        quickMenuItem = NSMenuItem(title: "快捷页面", action: nil, keyEquivalent: "")
        let quickMenu = NSMenu(title: "快捷页面")
        quickMenuItem.submenu = quickMenu
        rebuildQuickMenu(quickMenu)
        menu.addItem(quickMenuItem)

        menu.addItem(.separator())

        menu.addItem(makeItem("安装 dsh 插件…", symbol: "shippingbox", key: "6", action: #selector(openPluginDialog)))
        menu.addItem(makeItem("执行任意命令…", symbol: "chevron.left.forwardslash.chevron.right", key: "7", action: #selector(openCommandDialog)))

        menu.addItem(.separator())

        menu.addItem(makeItem("打开 Web 日志", symbol: "doc.text", key: "", action: #selector(openLog)))

        menu.addItem(.separator())

        menu.addItem(makeItem("退出 DSH Desktop", symbol: "power", key: "q", action: #selector(quitApp)))

        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, symbol: String, key: String, action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            mi.image = img
        }
        return mi
    }

    // MARK: 状态

    private func refreshStatus() {
        DispatchQueue.global().async {
            let pids = WebServerManager.shared.pidsOnPort(kWebPort)
            DispatchQueue.main.async {
                self.updateStatus(running: !pids.isEmpty, pids: pids)
            }
        }
    }

    private func updateStatus(running: Bool, pids: [Int32]) {
        guard let statusItem else { return }
        if running {
            let pidText = pids.first.map { " · pid \($0)" } ?? ""
            statusMenuItem.title = "● Web 运行中 · 端口 \(kWebPort)\(pidText)"
            restartItem.isEnabled = true
            stopItem.isEnabled = true
            startItem.title = "重启 dsh Web（已在运行）"
            startItem.image = NSImage(systemSymbolName: "arrow.clockwise",
                                      accessibilityDescription: "重启")
            startItem.action = #selector(restartWeb)
            statusItem.button?.toolTip = "DSH Web 运行中（pid \(pids.first.map { String($0) } ?? "-")）"
        } else {
            statusMenuItem.title = "○ Web 未运行"
            restartItem.isEnabled = false
            stopItem.isEnabled = false
            startItem.title = "启动 dsh Web"
            startItem.image = NSImage(systemSymbolName: "play.fill",
                                      accessibilityDescription: "启动")
            startItem.action = #selector(startWeb)
            statusItem.button?.toolTip = "DSH Web 未运行"
        }
    }

    // MARK: 动作

    @objc func startWeb() {
        let paths = ToolLocator.load()
        guard !paths.node.isEmpty, !paths.dsh.isEmpty else {
            showAlert("未找到 dsh / node",
                      "请确认已安装 dsh（`which dsh`），然后重新运行 build.sh 生成应用。")
            return
        }
        WebServerManager.shared.start()
        // 等待端口就绪后自动打开浏览器
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline, WebServerManager.shared.pidsOnPort(kWebPort).isEmpty {
                Thread.sleep(forTimeInterval: 0.4)
            }
            DispatchQueue.main.async {
                if !WebServerManager.shared.pidsOnPort(kWebPort).isEmpty {
                    // 需求 1：默认连接后使用全屏窗口打开页面，而不是浏览器
                    self.openAppWindow()
                } else {
                    self.showAlert("dsh Web 启动未就绪",
                                   "12 秒内端口 \(kWebPort) 未监听，请查看「打开 Web 日志」了解原因。")
                }
            }
        }
    }

    @objc func restartWeb() {
        WebServerManager.shared.restart()
        statusMenuItem.title = "↻ 正在重启…"
    }

    @objc func stopWeb() {
        statusMenuItem.title = "⏹ 正在停止…"
        WebServerManager.shared.stop { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }
    }

    @objc func openInBrowser() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(kWebPort)/")!)
    }

    /// 打开应用内置浏览器窗口，默认进入全屏（需求 1 / 4）
    @objc func openAppWindow() {
        if browserWindow == nil { browserWindow = BrowserWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        browserWindow?.present(select: nil, enterFullscreen: true)
    }

    /// 菜单刷新：打开/激活窗口并刷新当前标签页（需求 5）
    @objc func refreshWebPage() {
        if browserWindow == nil { browserWindow = BrowserWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        browserWindow?.present(select: nil, enterFullscreen: false)
        browserWindow?.refreshActive()
    }

    /// 快捷页面 → 打开/切换到对应快捷栏目的标签（并显示窗口）
    @objc func openQuickLink(_ sender: NSMenuItem) {
        let shortcutId = sender.representedObject as? String ?? "dsh"
        if browserWindow == nil { browserWindow = BrowserWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        browserWindow?.present(select: shortcutId, enterFullscreen: false)
    }

    /// 快捷栏目存储变更 → 重建「快捷页面」菜单
    @objc private func shortcutStoreChanged() {
        guard let menu = quickMenuItem.submenu else { return }
        rebuildQuickMenu(menu)
    }

    private func rebuildQuickMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for s in ShortcutStore.shared.items {
            let mi = NSMenuItem(title: s.name, action: #selector(openQuickLink(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s.id
            mi.toolTip = s.tipText.isEmpty ? s.url : s.tipText
            let symbol = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.name)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            if let file = s.iconFile, IconStore.load(file) != nil {
                mi.image = IconStore.load(file)   // 官网真实图标（不染色）
            } else if let symbol {
                mi.image = symbol.tinted(s.tint)
            }
            menu.addItem(mi)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "（暂无快捷栏目）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    /// 缩放（最大化）到 macOS 可用屏幕（需求 3）
    @objc func zoomWindow() {
        browserWindow?.zoom()
    }

    @objc func toggleFullscreenFromMenu() {
        browserWindow?.toggleFullscreen()
    }

    @objc func openActiveInExternalBrowser() {
        if let w = browserWindow?.window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        browserWindow?.openActiveInExternalBrowser()
    }

    /// 主菜单（编辑 / 浏览）：菜单栏应用虽不显示菜单栏，但主菜单仍参与快捷键分发，
    /// 提供 ⌘C/⌘V/⌘X/⌘A、⌘R、⌃⌘F、⌘⇧O 等标准快捷键。
    private func buildMainMenu() {
        let main = NSMenu()

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(editItem)

        let viewItem = NSMenuItem(title: "浏览", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "浏览")
        viewItem.submenu = viewMenu
        let refresh = NSMenuItem(title: "刷新页面", action: #selector(refreshWebPage), keyEquivalent: "r")
        refresh.target = self
        viewMenu.addItem(refresh)
        let zoom = NSMenuItem(title: "缩放（最大化）", action: #selector(zoomWindow), keyEquivalent: "")
        zoom.target = self
        viewMenu.addItem(zoom)
        let fullscreen = NSMenuItem(title: "进入/退出全屏", action: #selector(toggleFullscreenFromMenu), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        fullscreen.target = self
        viewMenu.addItem(fullscreen)
        let external = NSMenuItem(title: "在外部浏览器打开", action: #selector(openActiveInExternalBrowser), keyEquivalent: "o")
        external.keyEquivalentModifierMask = [.command, .shift]
        external.target = self
        viewMenu.addItem(external)
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    /// 启动时若 dsh web 已在运行，自动打开全屏窗口（需求 4）
    private func autoOpenIfWebRunning() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            let running = !WebServerManager.shared.pidsOnPort(kWebPort).isEmpty
            DispatchQueue.main.async {
                if running { self.openAppWindow() }
            }
        }
    }

    @objc func openPluginDialog() { showCommandPanel(mode: .plugin) }
    @objc func openCommandDialog() { showCommandPanel(mode: .generic) }

    private func showCommandPanel(mode: CommandPanel.Mode) {
        if commandPanel == nil { commandPanel = CommandPanel() }
        commandPanel?.configure(mode: mode)
        NSApp.activate(ignoringOtherApps: true)
        commandPanel?.makeKeyAndOrderFront(nil)
        commandPanel?.focusCommandField()
    }

    @objc func openLog() { AppLog.shared.openInFinder() }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: 工具

    private func showAlert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()