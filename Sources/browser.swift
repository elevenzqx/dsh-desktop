// DSH Desktop —— AI 网站导航窗口
// 功能:
//  - 顶部固定标签栏（高度小巧）：含可关闭的标签条 + 导航按钮（后退 / 前进 / 刷新 /
//    外部浏览器 / 全屏）。
//  - 左侧窄侧边栏：快捷按钮打开常用 AI 网页（豆包 / DeepSeek / 阿里千问 / 百度 / 腾讯元宝 /
//    DSH 插件 / DeepSeek 费用 / 硅基流动费用 等）；底部「设置」按钮配置快捷栏目。
//    主页（DSH Web）按钮固定，其余栏目可通过设置修改名称 / 网址 / 图标 / 颜色 / 排序。
//  - 动态标签页：同一快捷页只保留一个标签；切换页面不关闭（各标签独立保留浏览状态）；
//    每个标签可单独关闭以释放资源。
//  - 退出应用时保留 dsh web 后台运行。
import AppKit
import WebKit
import QuartzCore

let kShortcutsKey = "dshDesktop.shortcuts.v1"
let kShortcutsChanged = Notification.Name("dshDesktop.shortcutsChanged")

// MARK: - NSImage 着色（菜单图标用）

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}

// MARK: - 快捷条目图标资源（内置 bundle 优先，其次用户运行时抓取的缓存）

final class IconStore {
    static let shared = IconStore()

    /// 内置官网图标目录（build.sh 打包进 Resources/icons）
    private var bundleDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("icons", isDirectory: true)
    }
    /// 用户运行时抓取 / 替换的图标缓存目录
    private var cacheDir: URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DSHDesktop/icons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load(_ file: String) -> NSImage? {
        guard !file.isEmpty, let img = IconStore.shared.resolve(file) else { return nil }
        return img
    }

    /// 按文件名查找图标（先用户缓存，后 bundle 内置）
    private func resolve(_ file: String) -> NSImage? {
        if let dir = cacheDir, let data = try? Data(contentsOf: dir.appendingPathComponent(file)) {
            if let img = NSImage(data: data) { return img }
        }
        if let dir = bundleDir, let data = try? Data(contentsOf: dir.appendingPathComponent(file)) {
            if let img = NSImage(data: data) { return img }
        }
        return nil
    }

    /// 把抓取到的图标数据写入用户缓存（返回写入的文件名）
    static func save(_ data: Data, as file: String) -> String? {
        guard !file.isEmpty, let dir = IconStore.shared.cacheDir else { return nil }
        let url = dir.appendingPathComponent(file)
        do {
            try data.write(to: url)
            return file
        } catch {
            return nil
        }
    }
}

// MARK: - 官网图标抓取（配置面板「抓取官网图标」用，运行时网络请求）

enum FaviconFetcher {
    /// 从页面 URL 抓取官网图标：解析 HTML <link rel=icon>，兜底 /favicon.ico
    static func fetch(from urlString: String, completion: @escaping (String?) -> Void) {
        guard var url = URL(string: urlString), let host = url.host else {
            completion(nil); return
        }
        if url.scheme == nil { url = URL(string: "https://" + urlString) ?? url }
        let pageURL = url.scheme == "http" ? url : url
        let baseURL = pageURL
        let fileName = "favicon-\(host).png".replacingOccurrences(of: "/", with: "_")

        URLSession.shared.dataTask(with: pageURL) { data, _, _ in
            var iconURL: URL? = nil
            if let data, let html = String(data: data, encoding: .utf8) {
                iconURL = Self.parseIconLink(in: html, base: baseURL)
            }
            if iconURL == nil {
                // 兜底：站点根目录 favicon.ico
                iconURL = URL(string: "https://\(host)/favicon.ico")
            }
            guard let target = iconURL else { completion(nil); return }
            Self.downloadAndSave(from: target, fileName: fileName, completion: completion)
        }.resume()
    }

    /// 从 HTML 中解析 <link rel="icon" href="..."> / <link rel="shortcut icon" ...>
    private static func parseIconLink(in html: String, base: URL) -> URL? {
        let patterns = [
            #"<link[^>]+rel="[^"]*icon[^"]*"[^>]*href="([^"]+)""#,
            #"<link[^>]+href="([^"]+)"[^>]*rel="[^"]*icon[^"]*""#,
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                return URL(string: String(html[r]), relativeTo: base)?.absoluteURL
            }
        }
        return nil
    }

    private static func downloadAndSave(from url: URL, fileName: String, completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, !data.isEmpty, NSImage(data: data) != nil else {
                completion(nil); return
            }
            completion(IconStore.save(data, as: fileName))
        }.resume()
    }
}

// MARK: - 快捷条目模型（一条快捷栏目 = 一个 AI 网站）

struct Shortcut: Codable, Equatable {
    var id: String
    var name: String
    var url: String
    var symbol: String      // SF Symbol 名称（无官网图标时回退）
    var tintHex: String     // #RRGGBB
    var tip: String?        // tips 提示说明（悬停 tooltip / 配置面板展示）
    var iconFile: String?   // 真实官网图标文件名（内置或运行时抓取）；nil = 用 SF Symbol

    init(id: String, name: String, url: String, symbol: String,
         tintHex: String, tip: String? = nil, iconFile: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.symbol = symbol
        self.tintHex = tintHex
        self.tip = tip
        self.iconFile = iconFile
    }

    var urlValue: URL? { URL(string: url) }
    var tint: NSColor { Shortcut.color(fromHex: tintHex) }
    var tipText: String { tip ?? "" }

    /// 展示用图标：官网图标优先，缺省回退 SF Symbol
    var icon: NSImage? {
        if let file = iconFile, let img = IconStore.load(file) { return img }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: name)
    }

    static func color(fromHex hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return .systemBlue }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - 快捷栏目存储（UserDefaults 持久化，变更时广播通知）

final class ShortcutStore {
    static let shared = ShortcutStore()

    private(set) var items: [Shortcut] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: kShortcutsKey),
           let decoded = try? JSONDecoder().decode([Shortcut].self, from: data),
           !decoded.isEmpty {
            items = decoded
        } else {
            items = Self.defaults()
            persistNoNotify()
        }
    }

    func find(_ id: String) -> Shortcut? { items.first { $0.id == id } }

    func add(_ s: Shortcut) { items.append(s); save() }
    func update(_ s: Shortcut) {
        if let i = items.firstIndex(where: { $0.id == s.id }) { items[i] = s }
        else { items.append(s) }
        save()
    }
    func remove(id: String) {
        guard id != "dsh" else { return }   // 主页快捷按钮固定，不允许删除
        items.removeAll { $0.id == id }
        save()
    }
    func move(id: String, by offset: Int) {
        guard id != "dsh" else { return }   // 主页快捷按钮固定在第一个
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard j >= 0, j < items.count else { return }
        items.swapAt(i, j)
        save()
    }
    func resetToDefaults() {
        items = Self.defaults()
        save()
    }

    func save() {
        persistNoNotify()
        NotificationCenter.default.post(name: kShortcutsChanged, object: nil)
    }

    private func persistNoNotify() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: kShortcutsKey)
        }
    }

    /// 内置快捷栏目：常用 AI 网页 + DSH 相关页面
    /// - iconFile: 对应官网抓取的官方图标（打包进 Resources/icons）
    /// - tip:      tips 提示说明（侧边栏悬停 / 配置面板展示）
    static func defaults() -> [Shortcut] {
        [
            Shortcut(id: "dsh", name: "DSH Web",
                     url: "http://127.0.0.1:\(kWebPort)/",
                     symbol: "house.fill", tintHex: "#6366f1",
                     tip: "DSH Web 主控台（本机 dsh web）"),
            Shortcut(id: "doubao", name: "豆包",
                     url: "https://www.doubao.com/chat/",
                     symbol: "bubble.left.and.bubble.right.fill", tintHex: "#4f7cff",
                     tip: "豆包 · 字节跳动 AI 对话助手", iconFile: "doubao.png"),
            Shortcut(id: "deepseek", name: "DeepSeek",
                     url: "https://chat.deepseek.com/",
                     symbol: "sparkles", tintHex: "#4d6bfe",
                     tip: "DeepSeek 官网对话", iconFile: "deepseek.png"),
            Shortcut(id: "qwen", name: "阿里千问",
                     url: "https://chat.qwen.ai/",
                     symbol: "sun.max.fill", tintHex: "#8b5cf6",
                     tip: "阿里千问（Qwen）官网对话", iconFile: "qwen.png"),
            Shortcut(id: "baidu", name: "百度",
                     url: "https://chat.baidu.com/",
                     symbol: "magnifyingglass", tintHex: "#2932e1",
                     tip: "百度 AI 对话", iconFile: "baidu.png"),
            Shortcut(id: "tencent", name: "腾讯元宝",
                     url: "https://yuanbao.tencent.com/",
                     symbol: "dollarsign.circle.fill", tintHex: "#f59e0b",
                     tip: "腾讯元宝 AI 助手", iconFile: "yuanbao.png"),
            Shortcut(id: "plugin", name: "DSH 插件",
                     url: "https://deepseek1024.com/",
                     symbol: "shippingbox.fill", tintHex: "#f97316",
                     tip: "DSH 插件市场", iconFile: "plugin.png"),
            Shortcut(id: "deepseek-billing", name: "DeepSeek 费用",
                     url: "https://platform.deepseek.com/usage",
                     symbol: "chart.line.uptrend.xyaxis", tintHex: "#0ea5e9",
                     tip: "DeepSeek 平台用量与费用", iconFile: "ds-billing.png"),
            Shortcut(id: "siliconflow", name: "硅基流动费用",
                     url: "https://cloud.siliconflow.cn/me/bills",
                     symbol: "creditcard.fill", tintHex: "#14b8a6",
                     tip: "硅基流动云平台费用账单", iconFile: "siliconflow.png"),
        ]
    }
}

// MARK: - 支持复制/粘贴快捷键的 WKWebView
// 菜单栏应用（LSUIElement）不显示主菜单，WKWebView 默认无法通过 ⌘C/⌘V 复制粘贴；
// 这里在 keyDown 阶段把 ⌘C/⌘V/⌘X/⌘A 转发给响应链，让 Web 内容接管复制/粘贴。

final class CopyPasteWebView: WKWebView {
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command),
           !mods.contains(.option),
           !mods.contains(.control),
           let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "c":
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
                return
            case "v":
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
                return
            case "x":
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
                return
            case "a":
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - 带底色圆角图标的按钮（侧边栏 / 设置图标 / 颜色预览共用）
// 支持两种图标模式：SF Symbol（白色，随底色）或真实官网图标（原色，不染色）

class TintedIconButton: NSButton {
    var baseColor: NSColor = .systemBlue {
        didSet { layer?.backgroundColor = baseColor.cgColor }
    }
    private var appliedSize: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 3
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        imageScaling = .scaleProportionallyDown
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 固有内容尺寸即正方形（编辑面板等 Auto Layout 环境靠它获得正方形尺寸）
    override var intrinsicContentSize: NSSize {
        NSSize(width: appliedSize, height: appliedSize)
    }

    /// SF Symbol 模式：白色符号 + 底色
    func configure(symbol: String, tooltip: String, size: CGFloat) {
        appliedSize = size
        toolTip = tooltip
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: max(11, size * 0.42), weight: .semibold))
        contentTintColor = .white
        applySizeConstraints(size)
    }

    /// 真实官网图标模式：原色展示（不染色），底色作为衬底
    func configure(iconFile: String, tooltip: String, size: CGFloat) {
        appliedSize = size
        toolTip = tooltip
        image = IconStore.load(iconFile)
        contentTintColor = nil
        applySizeConstraints(size)
    }

    private func applySizeConstraints(_ size: CGFloat) {
        // 按钮尺寸不再通过 Auto Layout 约束控制：
        //  - 侧边栏内由 SidebarView 手动 frame 布局（约束在 scroll documentView
        //    子树只挂载不求解，实测会导致按钮被拉成矩形）；
        //  - 编辑面板 preview 等 Auto Layout 环境由 intrinsicContentSize（正方形）
        //    提供尺寸。
        // 这里只记录尺寸，供 intrinsicContentSize 使用。
        appliedSize = size
    }
}

// MARK: - 侧边栏快捷按钮（带“已打开 / 当前页”标记环）

final class ShortcutButton: TintedIconButton {
    let shortcut: Shortcut
    var isOpen = false { didSet { redraw() } }
    var isActive = false { didSet { redraw() } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { redraw() } }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        baseColor = shortcut.tint
        if let file = shortcut.iconFile, IconStore.load(file) != nil {
            configure(iconFile: file, tooltip: shortcut.name, size: 36)
        } else {
            configure(symbol: shortcut.symbol, tooltip: shortcut.name, size: 36)
        }
        toolTip = shortcut.tipText.isEmpty
            ? "\(shortcut.name) · \(shortcut.url)"
            : shortcut.tipText
        target = self
        action = #selector(pressed)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onClick?() }

    private func redraw() {
        layer?.borderWidth = (isOpen || hovered) ? 2 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(isActive ? 1 : (hovered ? 0.35 : 0.6)).cgColor
        layer?.shadowOpacity = isActive ? 0.55 : (hovered ? 0.5 : 0.28)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

// MARK: - 标签单元（顶栏标签条的一项：标题 + 关闭按钮）

final class TabCell: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var label: String = "" {
        didSet { titleButton.title = label; needsLayout = true }
    }
    var tint: NSColor = .systemBlue { didSet { updateStyle() } }
    var isActive = false { didSet { updateStyle(); needsLayout = true } }
    private var hover = false { didSet { updateStyle() } }

    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 12, weight: .medium)
        titleButton.target = self
        titleButton.action = #selector(selectPressed)
        titleButton.cell?.lineBreakMode = .byTruncatingTail
        addSubview(titleButton)

        let xImg = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭页面")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        closeButton.image = xImg
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "关闭页面（释放资源）"
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let bw = max(0, b.width - 26)
        titleButton.frame = NSRect(x: 8, y: 0, width: bw, height: b.height)
        closeButton.frame = NSRect(x: b.width - 22, y: (b.height - 14) / 2, width: 14, height: 14)
    }

    func measureWidth() -> CGFloat {
        let textW = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return min(max(textW + 50, 96), 200)
    }

    @objc private func selectPressed() { onSelect?() }
    @objc private func closePressed() { onClose?() }

    private func updateStyle() {
        if isActive {
            layer?.backgroundColor = tint.withAlphaComponent(0.30).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.9).cgColor
            layer?.borderWidth = 1
            titleButton.contentTintColor = .labelColor
            closeButton.contentTintColor = .labelColor
        } else if hover {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = 0
            titleButton.contentTintColor = .labelColor
            closeButton.contentTintColor = .secondaryLabelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            titleButton.contentTintColor = .secondaryLabelColor
            closeButton.contentTintColor = .tertiaryLabelColor
        }
        layer?.cornerRadius = 8
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
}

// MARK: - 标签条（水平排布多个标签单元）

final class TabStripView: NSView {
    private(set) var cells: [TabCell] = []

    var neededWidth: CGFloat {
        cells.reduce(0) { $0 + $1.measureWidth() } + CGFloat(max(0, cells.count - 1)) * 6
    }

    func setCells(_ newCells: [TabCell]) {
        cells.forEach { $0.removeFromSuperview() }
        cells = newCells
        cells.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for c in cells {
            let w = c.measureWidth()
            c.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w + 6
        }
    }
}

// MARK: - 顶栏视图（自动隐藏；左侧品牌区 + 标签条 + 导航按钮，手动布局）

final class TopBarView: NSView {
    var tabScroll: NSScrollView!
    var tabStrip: TabStripView!
    var backButton: NSButton!
    var forwardButton: NSButton!
    var reloadButton: NSButton!
    var externalButton: NSButton!
    var fullscreenButton: NSButton!
    var leftInset: CGFloat = 78 { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        guard let tabScroll = tabScroll,
              let tabStrip = tabStrip else { return }
        let b = bounds
        let h = b.height

        let navs: [NSButton?] = [backButton, forwardButton, reloadButton, externalButton, fullscreenButton]
        let navWidth = CGFloat(navs.count) * 32 + 8
        var bx = b.width - navWidth
        for btn in navs {
            guard let btn = btn else { continue }
            btn.frame = NSRect(x: bx, y: (h - 26) / 2, width: 28, height: 26)
            bx += 32
        }
        let navStart = b.width - navWidth
        let stripX = leftInset + 4
        tabScroll.frame = NSRect(x: stripX, y: 0, width: max(0, navStart - stripX - 4), height: h)
        tabScroll.layoutSubtreeIfNeeded()
        tabStrip.frame = NSRect(x: 0, y: 4,
                                width: max(tabStrip.neededWidth, tabScroll.contentView.bounds.width),
                                height: max(0, h - 8))
        tabStrip.needsLayout = true
        tabStrip.layoutSubtreeIfNeeded()
    }
}

// MARK: - 翻转内容视图（NSStackView 布局从上到下，需搭配 flipped 的 clip 才不会倒置）

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - 侧边栏（窄条：快捷按钮 + 底部添加 / 设置）

final class SidebarView: NSVisualEffectView {
    var onSelectShortcut: ((Shortcut) -> Void)?
    var onOpenSettings: (() -> Void)?

    /// 快捷按钮数组（手动 frame 布局；不再使用 scroll/stack/Auto Layout，
    /// 实测该子树下约束只挂载不求解，导致按钮被拉成矩形并引发递归崩溃）
    private var shortcutButtons: [TintedIconButton] = []
    private let settingsButton: TintedIconButton

    /// 布局参数（窄条侧边栏，全部图标按钮正方形）
    private let btnSide: CGFloat = 36
    private let btnGap: CGFloat = 10
    private let topInset: CGFloat = 16
    private let bottomGap: CGFloat = 12

    /// 配置页打开时设置按钮高亮（视觉反馈，再次点击返回浏览）
    var settingsActive = false {
        didSet {
            settingsButton.layer?.borderWidth = settingsActive ? 1.5 : 0
            settingsButton.layer?.borderColor = settingsActive
                ? NSColor.white.withAlphaComponent(0.9).cgColor : NSColor.clear.cgColor
            settingsButton.layer?.shadowOpacity = settingsActive ? 0.6 : 0.28
        }
    }

    init() {
        settingsButton = TintedIconButton(frame: .zero)
        settingsButton.configure(symbol: "gearshape.fill", tooltip: "设置 · 配置快捷栏目", size: 36)
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .active

        settingsButton.baseColor = Shortcut.color(fromHex: "#475569")
        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)
        addSubview(settingsButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 手动布局兜底：所有图标按钮强制为 36×36 正方形。
        // 不依赖 Auto Layout（约束在 scroll documentView 子树不可靠），
        // 也不依赖翻转性（用 bounds 高度统一按「底部对齐」计算）。
        let w = bounds.width
        let h = bounds.height
        let side = btnSide

        // 1) 设置按钮：底部居中（坐标方向按 isFlipped 自适应：
        //    翻转系原点在左上，底边 y = h - side - bottomGap；
        //    非翻转系原点在左下，底边 y = bottomGap）
        settingsButton.frame = NSRect(
            x: (w - side) / 2,
            y: isFlipped ? h - side - bottomGap : bottomGap,
            width: side, height: side)

        // 2) 快捷按钮：顶部向下垂直排列（16 顶距、36 高、10 间距）。
        //    坐标系方向按 isFlipped 自适应：翻转系从顶递增往下；
        //    非翻转系（默认，原点左下）从顶递减向下。
        var y: CGFloat
        func firstY() -> CGFloat { isFlipped ? topInset : h - topInset - side }
        func nextY(_ cur: CGFloat) -> CGFloat { cur + (isFlipped ? 1 : -1) * (side + btnGap) }
        y = firstY()
        for b in shortcutButtons {
            b.frame = NSRect(x: (w - side) / 2, y: y, width: side, height: side)
            y = nextY(y)
        }
    }

    func reload(shortcuts: [Shortcut], openIds: Set<String>, activeId: String?) {
        for b in shortcutButtons { b.removeFromSuperview() }
        shortcutButtons.removeAll()
        for s in shortcuts {
            let b = ShortcutButton(shortcut: s)
            b.isOpen = openIds.contains(s.id)
            b.isActive = (s.id == activeId)
            b.onClick = { [weak self] in self?.onSelectShortcut?(s) }
            addSubview(b)
            shortcutButtons.append(b)
        }
        needsLayout = true
    }

    @objc private func settingsPressed() { onOpenSettings?() }

    func stackCount() -> Int { shortcutButtons.count }

    /// DEBUG 探针：设置按钮运行时几何（排查按钮不可见 / 非正方形问题）
    func settingsButtonInfo() -> String {
        let s = settingsButton
        return "frame=\(s.frame) hidden=\(s.isHidden) alpha=\(s.alphaValue) enabled=\(s.isEnabled) "
            + "super=\(String(describing: type(of: s.superview))) sidebarFlipped=\(isFlipped) "
            + "subviews=\(subviews.count)"
    }
    /// DEBUG 探针：全部快捷按钮的 frame（检查是否正方形与排列顺序）
    func shortcutButtonFrames() -> String {
        shortcutButtons.enumerated().map { i, b in
            "#\(i):\(b.frame.width)x\(b.frame.height)@\(b.frame.origin.y)"
        }.joined(separator: " ")
    }
}

// MARK: - 快捷栏目编辑面板（名称 / 网址 / tips 提示 / 图标 / 颜色）

final class ShortcutEditPanel: NSPanel {
    private var original: Shortcut?
    private var chosenSymbol = "globe"
    private var chosenHex = "#6366f1"
    private var chosenIconFile: String?   // 官网图标文件名；nil = 用 SF Symbol
    var onSave: ((Shortcut) -> Void)?

    private let preview = TintedIconButton(frame: .zero)
    private let nameField = NSTextField(string: "")
    private let urlField = NSTextField(string: "")
    private let tipField = NSTextField(string: "")
    private let symbolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fetchIconButton = NSButton(title: "抓取官网图标", target: nil, action: nil)
    private let clearIconButton = NSButton(title: "清除图标", target: nil, action: nil)
    private let iconStateLabel = NSTextField(labelWithString: "")
    private let hexLabel = NSTextField(labelWithString: "")
    private var swatches: [NSButton] = []
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    private let symbolChoices = [
        "house.fill", "bubble.left.and.bubble.right.fill", "sparkles", "brain",
        "sun.max.fill", "magnifyingglass", "dollarsign.circle.fill", "shippingbox.fill",
        "chart.line.uptrend.xyaxis", "creditcard.fill", "globe", "bolt.fill",
        "wand.and.stars", "message.fill", "square.grid.2x2.fill", "atom",
        "circle.hexagongrid.fill", "cloud.fill", "flame.fill", "graduationcap.fill",
        "music.note", "tv.fill", "video.fill", "text.bubble.fill", "checkmark.seal.fill",
        "book.fill", "doc.text.fill", "pencil.and.scribble",
    ]
    private let colorChoices = [
        "#6366f1", "#4f7cff", "#4d6bfe", "#8b5cf6", "#2932e1", "#f59e0b", "#f97316",
        "#ef4444", "#ec4899", "#10b981", "#14b8a6", "#0ea5e9", "#64748b", "#475569",
    ]

    init(shortcut: Shortcut? = nil) {
        original = shortcut
        chosenSymbol = shortcut?.symbol ?? symbolChoices[0]
        chosenHex = shortcut?.tintHex ?? colorChoices[0]
        chosenIconFile = shortcut?.iconFile
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = shortcut == nil ? "添加快捷栏目" : "编辑快捷栏目"
        isReleasedWhenClosed = false
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        contentView = bg
        build()
        syncPreview()
    }
    required init?(coder: NSCoder) { fatalError() }

    func presentAsSheet(on parent: NSWindow, save: @escaping (Shortcut) -> Void) {
        onSave = save
        parent.beginSheet(self) { _ in }
        parent.makeFirstResponder(nameField)
    }

    // MARK: UI

    private func makeLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        guard let content = contentView else { return }

        preview.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 13)
        nameField.placeholderString = "名称，如：豆包"
        urlField.font = .systemFont(ofSize: 13)
        urlField.placeholderString = "网址，如：https://www.doubao.com/chat/"
        tipField.font = .systemFont(ofSize: 12)
        tipField.placeholderString = "tips 提示说明，如：豆包 · 字节跳动 AI 对话助手（悬停侧边栏按钮显示）"
        symbolPopup.font = .systemFont(ofSize: 12)
        symbolPopup.addItems(withTitles: symbolChoices)
        symbolPopup.selectItem(withTitle: chosenSymbol)
        iconStateLabel.font = .systemFont(ofSize: 11)
        iconStateLabel.textColor = .secondaryLabelColor
        iconStateLabel.lineBreakMode = .byTruncatingMiddle
        hexLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hexLabel.textColor = .secondaryLabelColor
        saveButton.bezelStyle = .rounded
        cancelButton.bezelStyle = .rounded
        fetchIconButton.bezelStyle = .rounded
        clearIconButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        fetchIconButton.target = self
        fetchIconButton.action = #selector(fetchIconPressed)
        clearIconButton.target = self
        clearIconButton.action = #selector(clearIconPressed)

        let nameLabel = makeLabel("名称")
        let urlLabel = makeLabel("网址")
        let tipLabel = makeLabel("tips 提示说明")
        let iconLabel = makeLabel("图标（官网图标 或 SF Symbol）")
        let colorLabel = makeLabel("颜色")

        let views: [NSView] = [preview, nameLabel, nameField, urlLabel, urlField,
                               tipLabel, tipField, iconLabel, symbolPopup,
                               fetchIconButton, clearIconButton, iconStateLabel,
                               colorLabel, hexLabel, cancelButton, saveButton]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        // 颜色色块
        let swatchSize: CGFloat = 18
        for (i, hex) in colorChoices.enumerated() {
            let b = NSButton(frame: .zero)
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = swatchSize / 2
            b.layer?.backgroundColor = Shortcut.color(fromHex: hex).cgColor
            b.toolTip = hex
            b.tag = i
            b.target = self
            b.action = #selector(swatchPressed(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(b)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: swatchSize),
                b.heightAnchor.constraint(equalToConstant: swatchSize),
            ])
            swatches.append(b)
        }
        updateSwatchRing()

        NSLayoutConstraint.activate([
            preview.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),

            nameLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            urlLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            urlLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            urlField.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 4),
            urlField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            urlField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            tipLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 12),
            tipLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tipField.topAnchor.constraint(equalTo: tipLabel.bottomAnchor, constant: 4),
            tipField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tipField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            iconLabel.topAnchor.constraint(equalTo: tipField.bottomAnchor, constant: 12),
            iconLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            symbolPopup.topAnchor.constraint(equalTo: iconLabel.bottomAnchor, constant: 4),
            symbolPopup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            symbolPopup.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            fetchIconButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            fetchIconButton.centerYAnchor.constraint(equalTo: symbolPopup.centerYAnchor),
            clearIconButton.trailingAnchor.constraint(equalTo: fetchIconButton.leadingAnchor, constant: -8),
            clearIconButton.centerYAnchor.constraint(equalTo: symbolPopup.centerYAnchor),

            iconStateLabel.topAnchor.constraint(equalTo: symbolPopup.bottomAnchor, constant: 4),
            iconStateLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            iconStateLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            colorLabel.topAnchor.constraint(equalTo: iconStateLabel.bottomAnchor, constant: 10),
            colorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hexLabel.centerYAnchor.constraint(equalTo: colorLabel.centerYAnchor),
            hexLabel.leadingAnchor.constraint(equalTo: colorLabel.trailingAnchor, constant: 10),

            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
        // 色块排布
        let first = swatches[0]
        NSLayoutConstraint.activate([
            first.topAnchor.constraint(equalTo: colorLabel.bottomAnchor, constant: 10),
            first.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        ])
        for i in 1..<swatches.count {
            let cur = swatches[i]
            let prev = swatches[i - 1]
            NSLayoutConstraint.activate([
                cur.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 8),
                cur.centerYAnchor.constraint(equalTo: prev.centerYAnchor),
            ])
        }
        swatches[0].bottomAnchor.constraint(lessThanOrEqualTo: cancelButton.topAnchor, constant: -14).isActive = true

        symbolPopup.target = self
        symbolPopup.action = #selector(symbolChanged(_:))
        nameField.stringValue = original?.name ?? ""
        urlField.stringValue = original?.url ?? ""
        tipField.stringValue = original?.tip ?? ""
    }

    private func updateSwatchRing() {
        for b in swatches {
            let selected = (colorChoices[b.tag] == chosenHex)
            b.layer?.borderWidth = selected ? 2 : 0
            b.layer?.borderColor = selected ? NSColor.labelColor.cgColor : NSColor.clear.cgColor
        }
    }

    private func syncPreview() {
        preview.baseColor = Shortcut.color(fromHex: chosenHex)
        if let file = chosenIconFile,
           IconStore.load(file) != nil {
            preview.configure(iconFile: file, tooltip: "官网图标 · \(chosenHex)", size: 44)
            iconStateLabel.stringValue = "当前：官网图标（\(file)）"
            clearIconButton.isEnabled = true
            symbolPopup.isEnabled = false
        } else {
            preview.configure(symbol: chosenSymbol, tooltip: "SF Symbol · \(chosenHex)", size: 44)
            iconStateLabel.stringValue = "当前：SF Symbol（\(chosenSymbol)）"
            clearIconButton.isEnabled = false
            symbolPopup.isEnabled = true
        }
        hexLabel.stringValue = chosenHex
        updateSwatchRing()
    }

    // MARK: 交互

    @objc private func symbolChanged(_ sender: NSPopUpButton) {
        if let t = sender.selectedItem?.title {
            chosenSymbol = t
            chosenIconFile = nil   // 用户选定 SF Symbol 即清除官网图标
            syncPreview()
        }
    }

    @objc private func swatchPressed(_ sender: NSButton) {
        chosenHex = colorChoices[sender.tag]
        syncPreview()
    }

    /// 从网址抓取官网图标（异步，成功后回填 iconFile）
    @objc private func fetchIconPressed() {
        let rawURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { NSSound.beep(); return }
        fetchIconButton.isEnabled = false
        iconStateLabel.stringValue = "正在抓取官网图标…"
        FaviconFetcher.fetch(from: rawURL) { [weak self] file in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fetchIconButton.isEnabled = true
                if let file {
                    self.chosenIconFile = file
                    self.syncPreview()
                } else {
                    self.iconStateLabel.stringValue = "未找到官网图标，可继续使用 SF Symbol"
                }
            }
        }
    }

    @objc private func clearIconPressed() {
        chosenIconFile = nil
        syncPreview()
    }

    @objc private func savePressed() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        var url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let tip = tipField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { NSSound.beep(); return }
        if !url.contains("://") { url = "https://" + url }
        guard let u = URL(string: url) else { NSSound.beep(); return }
        let id = original?.id ?? UUID().uuidString
        let iconFile = (chosenIconFile ?? "") == "" ? nil : chosenIconFile
        let symbol = (chosenIconFile == nil) ? chosenSymbol : (original?.symbol ?? chosenSymbol)
        onSave?(Shortcut(id: id, name: name, url: u.absoluteString,
                         symbol: symbol, tintHex: chosenHex,
                         tip: tip.isEmpty ? nil : tip, iconFile: iconFile))
        dismissSelf()
    }

    @objc private func cancelPressed() { dismissSelf() }

    private func dismissSelf() {
        if let p = sheetParent { p.endSheet(self, returnCode: .OK) }
        else { close() }
    }
}

// MARK: - 设置面板中的一行快捷栏目

final class ShortcutRowView: NSView {
    let shortcut: Shortcut
    let locked: Bool
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?

    private let icon: TintedIconButton
    private let lockBadge = NSTextField(labelWithString: "主页 · 固定")
    private let nameLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let upButton: NSButton
    private let downButton: NSButton
    private let editButton: NSButton
    private let deleteButton: NSButton

    init(shortcut: Shortcut, canUp: Bool, canDown: Bool, locked: Bool = false) {
        self.shortcut = shortcut
        self.locked = locked
        icon = TintedIconButton(frame: .zero)
        if let file = shortcut.iconFile, IconStore.load(file) != nil {
            icon.configure(iconFile: file, tooltip: shortcut.name, size: 30)
        } else {
            icon.configure(symbol: shortcut.symbol, tooltip: shortcut.name, size: 30)
        }
        upButton = ShortcutRowView.makeMini(symbol: "chevron.up", tip: "上移", color: .secondaryLabelColor, enabled: canUp && !locked)
        downButton = ShortcutRowView.makeMini(symbol: "chevron.down", tip: "下移", color: .secondaryLabelColor, enabled: canDown && !locked)
        editButton = ShortcutRowView.makeMini(symbol: "pencil", tip: "编辑", color: .secondaryLabelColor, enabled: !locked)
        deleteButton = ShortcutRowView.makeMini(symbol: "trash", tip: "删除", color: .systemRed, enabled: !locked)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor

        nameLabel.stringValue = shortcut.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        urlLabel.stringValue = shortcut.url
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle

        upButton.target = self; upButton.action = #selector(upPressed)
        downButton.target = self; downButton.action = #selector(downPressed)
        editButton.target = self; editButton.action = #selector(editPressed)
        deleteButton.target = self; deleteButton.action = #selector(deletePressed)

        if locked {
            upButton.isHidden = true
            downButton.isHidden = true
            editButton.isHidden = true
            deleteButton.isHidden = true
        }
        lockBadge.font = .systemFont(ofSize: 11, weight: .medium)
        lockBadge.textColor = .secondaryLabelColor
        lockBadge.isHidden = !locked

        var views: [NSView] = [icon, nameLabel, urlLabel, upButton, downButton, editButton, deleteButton]
        if locked { views.append(lockBadge) }
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }

        var cs: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -90),

            urlLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            urlLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            urlLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            urlLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -90),
        ]
        if locked {
            cs.append(lockBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12))
            cs.append(lockBadge.centerYAnchor.constraint(equalTo: centerYAnchor))
        } else {
            cs.append(contentsOf: [
                deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                editButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
                editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                downButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -4),
                downButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                upButton.trailingAnchor.constraint(equalTo: downButton.leadingAnchor, constant: -4),
                upButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate(cs)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func makeMini(symbol: String, tip: String, color: NSColor, enabled: Bool) -> NSButton {
        let b = NSButton(frame: .zero)
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        b.contentTintColor = color
        b.toolTip = tip
        b.isEnabled = enabled
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 24),
            b.heightAnchor.constraint(equalToConstant: 24),
        ])
        return b
    }

    @objc private func upPressed() { onUp?() }
    @objc private func downPressed() { onDown?() }
    @objc private func editPressed() { onEdit?() }
    @objc private func deletePressed() { onDelete?() }
}

// MARK: - 配置页（画布内切换的配置视图；左侧分区列表，后续可扩展更多配置分区）

final class ConfigPageView: NSView {
    var onDone: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "设置")
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)
    private let sectionList = NSStackView()
    private let contentBox = NSView()

    // 右侧「侧边栏配置」分区内容
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let addButton = NSButton(title: "＋ 添加", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let hintLabel = NSTextField(wrappingLabelWithString:
        "侧边栏图标即快捷入口，点击打开页面；同一页面只保留一个标签，切换不会关闭，每个标签可单独关闭以释放资源。删除快捷栏目会同时关闭其标签页。")

    /// 配置分区（后续扩展新分区只需在此追加条目，并在 switch 内返回对应内容视图）
    private let sections: [(id: String, title: String, note: String)] = [
        ("sidebar", "侧边栏配置", "图标 / 网址 / tips / 颜色 / 排序"),
        ("general", "通用设置", "敬请期待"),
        ("about", "关于", "敬请期待"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildHeader()
        buildSections()
        buildSidebarContent()
        selectSection(id: "sidebar")
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: kShortcutsChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var sectionButtons: [NSButton] = []
    private var sidebarBox: NSView!

    /// 顶栏：标题 + 完成按钮
    private func buildHeader() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(donePressed)

        [titleLabel, doneButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            doneButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    /// 左侧分区列表（后续扩展分区只需在 sections 追加，并扩展 selectSection）
    private func buildSections() {
        sectionList.orientation = .vertical
        sectionList.alignment = .leading
        sectionList.spacing = 2
        sectionList.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        sectionList.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionList)

        contentBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentBox)

        for (i, sec) in sections.enumerated() {
            let b = NSButton(title: sec.title, target: self, action: #selector(sectionPressed(_:)))
            b.tag = i
            b.alignment = .left
            b.bezelStyle = .inline
            b.font = .systemFont(ofSize: 13, weight: .medium)
            b.toolTip = sec.note
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 132).isActive = true
            sectionList.addArrangedSubview(b)
            sectionButtons.append(b)
        }

        NSLayoutConstraint.activate([
            sectionList.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            sectionList.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionList.bottomAnchor.constraint(equalTo: bottomAnchor),
            sectionList.widthAnchor.constraint(equalToConstant: 150),

            contentBox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            contentBox.leadingAnchor.constraint(equalTo: sectionList.trailingAnchor),
            contentBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentBox.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 右侧「侧边栏配置」分区内容（快捷栏目列表 + 添加 / 恢复默认）
    private func buildSidebarContent() {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        sidebarBox = box

        let title = NSTextField(labelWithString: "快捷栏目")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addPressed)
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restorePressed)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 420
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        scroll.contentView = clip
        scroll.documentView = stack

        let views: [NSView] = [title, addButton, scroll, hintLabel, restoreButton]
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),

            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),

            addButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -14),

            hintLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: restoreButton.leadingAnchor, constant: -8),
            hintLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),

            restoreButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
            restoreButton.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
        ])
    }

    /// 切换分区内容（通用 / 关于等暂为占位，后续扩展在此接入）
    private func selectSection(id: String) {
        for (i, b) in sectionButtons.enumerated() {
            let active = (sections[i].id == id)
            b.contentTintColor = active ? .labelColor : .tertiaryLabelColor
            let accent = NSColor.controlAccentColor.withAlphaComponent(active ? 0.22 : 0)
            b.layer?.backgroundColor = accent.cgColor
            b.layer?.cornerRadius = 6
            b.wantsLayer = true
        }
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        if id == "sidebar" {
            contentBox.addSubview(sidebarBox)
            NSLayoutConstraint.activate([
                sidebarBox.topAnchor.constraint(equalTo: contentBox.topAnchor),
                sidebarBox.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
                sidebarBox.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
                sidebarBox.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
            ])
        } else {
            let ph = NSTextField(wrappingLabelWithString: "该配置分区将在后续版本开放，敬请期待。")
            ph.font = .systemFont(ofSize: 13)
            ph.textColor = .secondaryLabelColor
            ph.preferredMaxLayoutWidth = 320
            ph.translatesAutoresizingMaskIntoConstraints = false
            contentBox.addSubview(ph)
            NSLayoutConstraint.activate([
                ph.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor),
                ph.centerYAnchor.constraint(equalTo: contentBox.centerYAnchor),
            ])
        }
    }

    @objc private func sectionPressed(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < sections.count else { return }
        selectSection(id: sections[idx].id)
    }

    @objc private func donePressed() { onDone?() }

    /// 更新快捷栏目列表
    func refresh() {
        if sidebarBox == nil { buildSidebarContent() }
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        let items = ShortcutStore.shared.items
        for (i, s) in items.enumerated() {
            let row = ShortcutRowView(shortcut: s, canUp: i > 0, canDown: i < items.count - 1, locked: s.id == "dsh")
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onUp = { [weak self] in ShortcutStore.shared.move(id: s.id, by: -1); self?.refresh() }
            row.onDown = { [weak self] in ShortcutStore.shared.move(id: s.id, by: 1); self?.refresh() }
            row.onEdit = { [weak self] in self?.presentEdit(s) }
            row.onDelete = { [weak self] in self?.confirmDelete(s) }
            stack.addArrangedSubview(row)
        }
    }

    private func presentEdit(_ s: Shortcut?) {
        let panel = ShortcutEditPanel(shortcut: s)
        guard let win = window else { return }
        panel.presentAsSheet(on: win) { newS in
            ShortcutStore.shared.update(newS)
        }
    }

    private func confirmDelete(_ s: Shortcut) {
        let a = NSAlert()
        a.messageText = "删除快捷栏目"
        a.informativeText = "将删除「\(s.name)」，并关闭其已打开的标签页。"
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            ShortcutStore.shared.remove(id: s.id)
        }
    }

    @objc private func storeChanged() { refresh() }

    @objc private func addPressed() { presentEdit(nil) }
    func beginAdd() { presentEdit(nil) }

    @objc private func restorePressed() {
        let a = NSAlert()
        a.messageText = "恢复默认快捷栏目"
        a.informativeText = "将用内置默认栏目（豆包 / DeepSeek / 阿里千问 / 百度 / 腾讯元宝 / DSH 页面等）替换当前列表。"
        a.addButton(withTitle: "恢复")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            ShortcutStore.shared.resetToDefaults()
        }
    }
}

// MARK: - 浏览器窗口控制器

final class BrowserWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {

    /// 一个标签页：对应一条快捷栏目，独立保存浏览状态
    final class Tab {
        let id: String
        var shortcut: Shortcut
        let webView: CopyPasteWebView
        var webTitle = ""
        init(id: String, shortcut: Shortcut, webView: CopyPasteWebView) {
            self.id = id
            self.shortcut = shortcut
            self.webView = webView
        }
    }

    private var tabs: [Tab] = []
    private var activeId: String?
    private var hasShownOnce = false
    private var isFullscreen = false
    private var configPage: ConfigPageView?

    private let topBarH: CGFloat = 40
    private let sideWidth: CGFloat = 58

    private var root: NSView!
    private var topBarView: TopBarView!
    private var topBarHeight: NSLayoutConstraint!
    private var sidebar: SidebarView!
    private var webContainer: NSView!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "DSH Web"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.setFrameAutosaveName("dshDesktop.webWindow")
        self.init(window: window)
        buildLayout()
        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutStoreChanged),
                                               name: kShortcutsChanged, object: nil)
        // 默认打开 DSH Web 首页
        openOrSelect(shortcutId: "dsh")
        if ProcessInfo.processInfo.environment["DSH_DESKTOP_DEBUG"] != nil {
            fputs("[selftest] window inited\n", stderr)
        }
    }

    // MARK: - 对外接口（供菜单调用）

    /// 显示窗口；select 指定要激活/打开的快捷栏目 id；enterFullscreen 为 true 时进入全屏
    func present(select tabId: String?, enterFullscreen: Bool) {
        guard let window else { return }
        if let id = tabId { openOrSelect(shortcutId: id) }
        if !hasShownOnce {
            window.center()
            hasShownOnce = true
        }
        showWindow(nil)
        window.orderFrontRegardless()
        if let t = activeTab() { window.makeFirstResponder(t.webView) }
        if enterFullscreen && !window.styleMask.contains(.fullScreen) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.window?.toggleFullScreen(nil)
            }
        }
        if ProcessInfo.processInfo.environment["DSH_DESKTOP_DEBUG"] != nil {
            fputs("[selftest] present frames=\(window.frame) tabs=\(tabs.count)\n", stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, let w = self.window else { return }
                fputs("[selftest] after3s visible=\(w.isVisible) fs=\(w.styleMask.contains(.fullScreen)) num=\(w.windowNumber) frame=\(w.frame) tabCount=\(self.tabs.count) barH=\(self.topBarHeight.constant) sidebarStack=\(self.sidebar.stackCount()) sidebarFrame=\(self.sidebar.frame) settings=\(self.sidebar.settingsButtonInfo()) shortcuts=[\(self.sidebar.shortcutButtonFrames())]\n", stderr)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    self.dumpPNG(self.sidebar, to: "build-verify/ui-sidebar.png")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self = self, let cv = self.window?.contentView else { return }
                        self.dumpPNG(cv, to: "build-verify/ui-window.png")
                        self.openSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            guard let self = self, let page = self.configPage else { return }
                            self.dumpPNG(page, to: "build-verify/ui-config.png")
                            self.closeConfigPage()
                        }
                    }
                }
            }
        }
    }

    func refreshActive() {
        activeTab()?.webView.reload()
    }
    func zoom() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.performZoom(nil)
    }
    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }
    func openActiveInExternalBrowser() {
        guard let t = activeTab() else { return }
        if let u = t.webView.url ?? t.shortcut.urlValue {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: - 构建

    private func buildLayout() {
        guard let window else { return }
        root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = root

        topBarView = TopBarView()
        topBarView.wantsLayer = true
        topBarView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topBarView)

        sidebar = SidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.onSelectShortcut = { [weak self] s in self?.openOrSelect(shortcutId: s.id) }
        sidebar.onOpenSettings = { [weak self] in self?.openSettings() }
        root.addSubview(sidebar)

        webContainer = NSView()
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webContainer)

        topBarHeight = topBarView.heightAnchor.constraint(equalToConstant: topBarH)
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: root.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBarHeight,

            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sideWidth),

            webContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        buildTopBarContent()
    }

    private func buildTopBarContent() {
        let strip = TabStripView()
        topBarView.tabStrip = strip

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .automatic
        scroll.documentView = strip
        topBarView.tabScroll = scroll
        topBarView.addSubview(scroll)

        let back = makeBarButton(symbol: "chevron.left", tip: "后退", action: #selector(backPressed))
        let forward = makeBarButton(symbol: "chevron.right", tip: "前进", action: #selector(forwardPressed))
        let reload = makeBarButton(symbol: "arrow.clockwise", tip: "刷新", action: #selector(reloadPressed))
        let external = makeBarButton(symbol: "safari", tip: "在浏览器中打开", action: #selector(externalPressed))
        let fullscreen = makeBarButton(symbol: "arrow.up.left.and.arrow.down.right",
                                       tip: "切换全屏", action: #selector(fullscreenPressed))
        topBarView.backButton = back
        topBarView.forwardButton = forward
        topBarView.reloadButton = reload
        topBarView.externalButton = external
        topBarView.fullscreenButton = fullscreen
        back.isEnabled = false
        forward.isEnabled = false
        for b in [back, forward, reload, external, fullscreen] {
            topBarView.addSubview(b)
        }
    }

    private func dumpPNG(_ view: NSView, to path: String) {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            fputs("[selftest] dumped \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)\n", stderr)
        }
    }

    private func makeBarButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .labelColor
        b.imageScaling = .scaleProportionallyDown
        return b
    }

    // MARK: - 标签管理

    private func activeTab() -> Tab? { tabs.first { $0.id == activeId } }

    private func openOrSelect(shortcutId: String) {
        var s = ShortcutStore.shared.find(shortcutId)
        if s == nil { s = ShortcutStore.shared.items.first }
        if s == nil {
            s = Shortcut(id: "dsh", name: "DSH Web",
                         url: "http://127.0.0.1:\(kWebPort)/",
                         symbol: "house.fill", tintHex: "#6366f1")
        }
        guard let shortcut = s else { return }
        if let existing = tabs.first(where: { $0.id == shortcut.id }) {
            existing.shortcut = shortcut
            select(tabId: existing.id)
            return
        }
        // 新建标签：独立保留浏览状态（切换不关闭）
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // Cookie 持久化，登录态跨启动保留
        let wv = CopyPasteWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.isHidden = true
        webContainer.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: webContainer.topAnchor),
            wv.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
        let tab = Tab(id: shortcut.id, shortcut: shortcut, webView: wv)
        tabs.append(tab)
        wv.load(URLRequest(url: shortcut.urlValue ?? URL(string: "about:blank")!))
        select(tabId: tab.id)
    }

    private func select(tabId: String) {
        guard let t = tabs.first(where: { $0.id == tabId }) else { return }
        closeConfigPage()   // 选择任意标签/快捷页时退出配置页，回到浏览
        activeId = tabId
        for other in tabs {
            other.webView.isHidden = (other.id != tabId)
        }
        window?.makeFirstResponder(t.webView)
        rebuildTabStrip()
        reloadSidebar()
        updateTitle()
        updateNavButtons()
    }

    /// 关闭标签页：释放该页 WKWebView 资源；切换页面不关闭，仅关闭时释放
    private func closeTab(tabId: String, force: Bool = false) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if tabs.count <= 1 && !force {
            NSSound.beep()
            return
        }
        let t = tabs[idx]
        t.webView.stopLoading()
        t.webView.navigationDelegate = nil
        t.webView.removeFromSuperview()
        tabs.remove(at: idx)
        if activeId == tabId {
            let next = tabs[min(idx, tabs.count - 1)]
            activeId = next.id
            select(tabId: next.id)
        } else {
            rebuildTabStrip()
            reloadSidebar()
        }
    }

    private func rebuildTabStrip() {
        var cells: [TabCell] = []
        for t in tabs {
            let cell = TabCell()
            cell.label = t.shortcut.name
            cell.tint = t.shortcut.tint
            cell.isActive = (t.id == activeId)
            cell.onSelect = { [weak self] in self?.select(tabId: t.id) }
            cell.onClose = { [weak self] in self?.closeTab(tabId: t.id) }
            cells.append(cell)
        }
        topBarView.tabStrip.setCells(cells)
        topBarView.needsLayout = true
    }

    private func reloadSidebar() {
        sidebar.reload(shortcuts: ShortcutStore.shared.items,
                       openIds: Set(tabs.map { $0.id }),
                       activeId: activeId)
    }

    private func updateTitle() {
        guard let t = activeTab() else { return }
        window?.title = t.webTitle.isEmpty ? t.shortcut.name : "\(t.shortcut.name) · \(t.webTitle)"
    }

    private func updateNavButtons() {
        topBarView.backButton.isEnabled = activeTab()?.webView.canGoBack ?? false
        topBarView.forwardButton.isEnabled = activeTab()?.webView.canGoForward ?? false
    }

    @objc private func shortcutStoreChanged() {
        let valid = Set(ShortcutStore.shared.items.map { $0.id })
        for id in tabs.map({ $0.id }) where !valid.contains(id) {
            closeTab(tabId: id, force: true)   // 快捷栏目被删除 → 关闭其标签，释放资源
        }
        for t in tabs {
            if let s = ShortcutStore.shared.find(t.id) { t.shortcut = s }
        }
        if tabs.isEmpty { openOrSelect(shortcutId: "dsh") }
        reloadSidebar()
        rebuildTabStrip()
        updateTitle()
    }

    // MARK: - 设置（画布内切换为配置页）

    private func openSettings(adding: Bool = false) {
        if configPage == nil {
            let page = ConfigPageView()
            page.onDone = { [weak self] in self?.openSettings() }   // 「完成」= 切换回浏览（再点设置也返回）
            configPage = page
        }
        guard let page = configPage else { return }
        if page.superview != nil {
            closeConfigPage()   // 配置页已打开：再点设置按钮返回浏览
            return
        }
        page.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: webContainer.topAnchor),
            page.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
        // 画布切换：隐藏所有 Web 视图，显示配置页
        for t in tabs { t.webView.isHidden = true }
        if adding { page.beginAdd() }
        sidebar.settingsActive = true
        reloadSidebar()
    }

    private func closeConfigPage() {
        guard configPage?.superview != nil else { return }
        configPage?.removeFromSuperview()
        if let t = activeTab() {
            t.webView.isHidden = false
            window?.makeFirstResponder(t.webView)
        }
        sidebar.settingsActive = false
        rebuildTabStrip()
        reloadSidebar()
        updateTitle()
        updateNavButtons()
    }

    // MARK: - 导航动作

    @objc private func backPressed() { activeTab()?.webView.goBack() }
    @objc private func forwardPressed() { activeTab()?.webView.goForward() }
    @objc private func reloadPressed() { refreshActive() }
    @objc private func externalPressed() { openActiveInExternalBrowser() }
    @objc private func fullscreenPressed() { toggleFullscreen() }

    // MARK: - 导航回调

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let t = tabs.first(where: { $0.webView === webView }), t.id == activeId {
            updateTitle(); updateNavButtons()
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let t = tabs.first(where: { $0.webView === webView }), t.id == activeId {
            updateTitle(); updateNavButtons()
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let t = tabs.first(where: { $0.webView === webView }) {
            t.webTitle = webView.title ?? ""
            if t.id == activeId { updateTitle(); updateNavButtons() }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let t = tabs.first(where: { $0.webView === webView }), t.id == activeId {
            window?.title = "\(t.shortcut.name) · 加载失败"
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let t = tabs.first(where: { $0.webView === webView }), t.id == activeId {
            window?.title = "\(t.shortcut.name) · 加载失败"
        }
    }

    // MARK: - 窗口行为

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        defaultFrame
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullscreen = true
        topBarView.leftInset = 14
        topBarView.needsLayout = true
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        topBarView.leftInset = 78
        topBarView.needsLayout = true
    }
}