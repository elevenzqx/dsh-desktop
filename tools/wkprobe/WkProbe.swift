// WkProbe —— WKWebView 卡死复现探针（与 DSH Desktop 同引擎、同配置）
// 用法: swiftc -O -o wkprobe WkProbe.swift && ./wkprobe "http://127.0.0.1:3080/" [result-file]
// 流程: 打开页面 -> 依次触发各弹窗/菜单/页面 -> 每步用 JS 定时器探针测主线程响应
//       若探针超时 => 主线程卡死（复现成功）。结果写入 stdout 与可选的 result 文件。
// 触发条目:  (label, close)  close=esc 关闭弹窗; none 不关闭; §RESET 页内导航重置(回到主界面)

import AppKit
import WebKit

let kProbeJS = "return new Promise(function(res){ setTimeout(function(){ res(String(Math.round(performance.now()))); }, 60); })"

let kTriggers: [(label: String, close: String)] = [
    // Phase A — 主页基础触发点
    ("设置", "esc"),
    // Phase B — 设置弹窗内的左侧分区导航（逐个打开并探测）
    ("通用设置", "esc"),
    ("模型", "esc"),
    ("插件", "esc"),
    ("技能", "esc"),
    ("MCP", "esc"),
    ("Agent 预设", "esc"),
    ("记忆系统", "esc"),
    ("文件提及", "esc"),
    ("侧边卡片", "esc"),
    ("Web 插件", "esc"),
    ("皮肤", "esc"),
    ("宠物", "esc"),
    ("创意工坊", "esc"),
    ("使用统计", "esc"),
    // Phase C — Web 插件区二级弹窗
    ("远程访问设置", "esc"),
    ("性能引擎", "esc"),
    ("任务看板", "esc"),
    ("图像理解", "esc"),
    ("桌面启动器", "esc"),
    ("Doctor 恢复控制台", "esc"),
    // Phase D — 回主页, 右侧边栏 / 工作区
    ("§RESET", "none"),
    ("展开侧边栏", "none"),
    ("收起侧边栏", "esc"),
    ("展开底部面板", "none"),
    ("折叠底部面板", "none"),
    // Phase E — 底栏各页
    ("文件", "none"),
    ("源代码管理", "none"),
    ("任务管理", "none"),
    ("侧边对话(beta)", "none"),
    ("终端", "none"),
    ("浏览器", "none"),
    // Phase F — 浏览器标签页工具栏（含用户提到的刷新按钮）
    ("网页截图存入灵感库", "esc"),
    ("刷新", "none"),
    ("新建标签页", "none"),
    ("上传文件", "none"),
    ("上传文件夹", "none"),
    ("关闭详情", "none"),
]

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var resultFile: String?
    var navigationDone = false
    var startURL: URL!
    var lastPing = 0.0
    var stepNo = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        window = NSWindow(contentRect: union, styleMask: style, backing: .buffered, defer: false)
        window.title = "WkProbe"
        window.isReleasedWhenClosed = false
        window.setFrame(union, display: true)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(origin: .zero, size: union.size), configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        window.contentView = webView
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: startURL))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.waitLoadThenProbe()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationDone = true
        log("NAV_FINISH url=\(webView.url?.absoluteString ?? "nil")")
    }

    func log(_ s: String) {
        fputs("[WkProbe] \(s)\n", stdout)
        fflush(stdout)
        if let rf = resultFile, let d = ("[WkProbe] \(s)\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: rf)) {
                h.seekToEndOfFile(); h.write(d); try? h.close()
            } else {
                try? d.write(to: URL(fileURLWithPath: rf))
            }
        }
    }

    private func waitLoadThenProbe() {
        let deadline = Date().addingTimeInterval(30)
        func check() {
            if navigationDone || Date() > deadline {
                startProbe()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check() }
            }
        }
        check()
    }

    /// 同步评估 (点击等), 超时返回 nil
    private func evalJS(_ js: String, timeout: TimeInterval, onDone: @escaping (String?) -> Void) {
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !finished { finished = true; onDone(nil) }
        }
        webView.evaluateJavaScript(js) { res, err in
            let value: String? = {
                if let err = err { return "ERR:\(err.localizedDescription)" }
                if let s = res as? String { return s }
                return res == nil ? "VOID" : "OK"
            }()
            if !finished {
                finished = true
                onDone(value)
            } else {
                self.log("LATE return: \(value ?? "nil") (页面恢复?)")
            }
        }
    }

    /// 异步评估 (await Promise 的探针), 超时返回 nil —— 真·主线程响应测量
    private func evalAsyncJS(_ js: String, timeout: TimeInterval, onDone: @escaping (String?) -> Void) {
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !finished { finished = true; onDone(nil) }
        }
        Task { @MainActor in
            let value: String?
            do {
                let v = try await webView.callAsyncJavaScript(js, contentWorld: .page)
                value = v == nil ? "VOID" : "\(v!)"
            } catch {
                value = "ERR:\(error.localizedDescription)"
            }
            if !finished {
                finished = true
                onDone(value)
            } else {
                self.log("LATE return: \(value ?? "nil") (页面恢复?)")
            }
        }
    }

    private func startProbe() {
        log("SETTLE ...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.runStep(0)
        }
    }

    private func runStep(_ idx: Int) {
        guard idx < kTriggers.count else {
            log("ALL_DONE")
            NSApp.terminate(nil)
            return
        }
        let t = kTriggers[idx]
        stepNo = idx

        // §RESET: 页内导航重置（回主页）
        if t.label.hasPrefix("§RESET") {
            navReset { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.runStep(idx + 1) }
            }
            return
        }

        // 先点开
        let clickJS = "(function(){var l=arguments[0];var b=[].slice.call(document.querySelectorAll('button')).find(function(x){var txt=(x.innerText||x.getAttribute('aria-label')||'').trim();return txt===l||txt.indexOf(l)>=0;});if(!b)return 'NF';b.click();return 'OK';})('\(t.label)')"
        evalJS(clickJS, timeout: 3.0) { [weak self] r in
            guard let self = self else { return }
            self.log("STEP \(idx) [\(t.label)] click=\(r ?? "TIMEOUT")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.evalAsyncJS(kProbeJS, timeout: 4.0) { p in
                    let pv = p ?? "TIMEOUT-卡死!"
                    self.log("STEP \(idx) [\(t.label)] ping=\(pv)")
                    if p == nil {
                        self.log("FREEZE_DETECTED at STEP \(idx) [\(t.label)]")
                        self.webView.reload()
                        self.log("NATIVE_RELOAD sent")
                        self.navigationDone = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                            self.evalAsyncJS(kProbeJS, timeout: 4.0) { p2 in
                                self.log("AFTER_RELOAD ping=\(p2 ?? "TIMEOUT")")
                                self.log("ALL_DONE")
                                NSApp.terminate(nil)
                            }
                        }
                        return
                    }
                    // 关闭弹窗
                    if t.close == "esc" {
                        self.evalJS("(function(){var d=document.querySelector('[role=dialog],[class*=overlay],[class*=Overlay]');var b=d&&[].slice.call(d.querySelectorAll('button')).find(function(x){return (x.innerText||'').trim()==='关闭';});if(b){b.click();return 'CLOSED';}document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return 'ESC';})()", timeout: 2.0) { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                self.evalJS("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));'esc2'", timeout: 2.0) { _ in
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.runStep(idx + 1) }
                                }
                            }
                        }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.runStep(idx + 1) }
                    }
                }
            }
        }
    }

    /// 页内导航重置: 点击侧边栏“主页/新会话”项并回主页
    private func navReset(onDone: @escaping () -> Void) {
        evalJS("window.location.href='\(startURL.absoluteString)';'nav'", timeout: 3.0) { _ in
            onDone()
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 2, let url = URL(string: args[1]) else {
    fputs("usage: wkprobe <url> [result-file]\n", stderr)
    exit(2)
}
let app = NSApplication.shared
let delegate = AppDelegate()
delegate.startURL = url
if args.count >= 3 { delegate.resultFile = args[2] }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()