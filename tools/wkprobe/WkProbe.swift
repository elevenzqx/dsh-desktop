// WkProbe —— WKWebView 卡死复现探针（与 DSH Desktop 同引擎、同配置）
// 用法: swiftc -O -o wkprobe WkProbe.swift && ./wkprobe "http://127.0.0.1:3080/" [result-file]
// 流程: 打开页面 -> 依次触发工作区/弹窗操作 -> 每步用 JS 定时器探针测主线程响应,
//       支持 hold 秒数持续探测（捕捉慢冻结）。探测超时 => 主线程卡死（复现成功）。

import AppKit
import WebKit

let kProbeJS = "return new Promise(function(res){ setTimeout(function(){ res(String(Math.round(performance.now()))); }, 60); })"

/// 触发条目: (label 或特殊指令, close, hold秒)
let kTriggers: [(label: String, close: String, hold: Double)] = [
    ("§EXPAND", "none", 0.0),
    ("源代码管理", "none", 15.0),
    ("任务管理", "none", 3.0),
    ("侧边对话(beta)", "none", 3.0),
    ("终端", "none", 3.0),
    ("文件", "none", 0.0),
    ("README.md", "none", 4.0),
    ("浏览器", "none", 0.0),
    ("刷新", "none", 5.0),
    ("新建标签页", "none", 2.0),
    ("上传文件", "none", 2.0),
    ("上传文件夹", "none", 2.0),
    ("关闭详情", "none", 0.0),
    ("§RESET", "none", 0.0),
    // 设置弹窗 + 左侧分区
    ("设置", "esc", 1.0),
    ("皮肤", "esc", 4.0),
    ("宠物", "esc", 4.0),
    ("创意工坊", "esc", 4.0),
    ("使用统计", "esc", 4.0),
    ("Web 插件", "esc", 1.0),
    ("性能引擎", "esc", 4.0),
    ("任务看板", "esc", 4.0),
    ("远程访问设置", "esc", 4.0),
    ("Doctor 恢复控制台", "esc", 4.0),
    ("记忆系统", "esc", 4.0),
    // 主页弹窗类
    ("§RESET", "none", 0.0),
    ("选择工作区", "esc", 1.0),
    ("Workspace Write", "esc", 2.0),
    ("标准模式", "esc", 2.0),
    ("命令", "esc", 2.0),
]

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var resultFile: String?
    var navigationDone = false
    var startURL: URL!

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

    /// 通用点击: 先按文本找 button/[role=tab]/[role=button], 找不到则按坐标点 (x,y) 用 elementFromPoint
    private func clickScript(_ label: String) -> String {
        "(function(){" +
        "var l=arguments[0];" +
        "var els=[].slice.call(document.querySelectorAll('button,[role=tab],[role=button],[role=menuitem],a')).filter(function(x){" +
        "  var r=x.getBoundingClientRect(); if(r.width===0||r.height===0)return false;" +
        "  var txt=(x.innerText||x.getAttribute('aria-label')||x.title||'').trim(); return txt===l||txt.indexOf(l)>=0;" +
        "});" +
        "if(els.length){ els[0].click(); return 'TXT'; }" +
        "return 'NF';" +
        "})('\(label)')"
    }

    private func runStep(_ idx: Int) {
        guard idx < kTriggers.count else {
            log("ALL_DONE")
            NSApp.terminate(nil)
            return
        }
        let t = kTriggers[idx]

        if t.label.hasPrefix("§RESET") {
            evalJS("window.location.href='\(startURL.absoluteString)';'nav'", timeout: 3.0) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.log("RESET nav done")
                    self.runStep(idx + 1)
                }
            }
            return
        }
        if t.label.hasPrefix("§EXPAND") {
            // 展开底部面板: 尝试文本, 再尝试右上角 (窗口宽-56, 17)
            let js = "(function(){var w=window.innerWidth;" +
                "var els=[].slice.call(document.querySelectorAll('button')).filter(function(x){" +
                "var txt=(x.innerText||x.getAttribute('aria-label')||x.title||'').trim();" +
                "return txt.indexOf('展开底部')>=0||txt.indexOf('折叠底部')>=0||txt.indexOf('底部面板')>=0;" +
                "});" +
                "if(els.length){els[0].click();return 'TXT';}" +
                "var el=document.elementFromPoint(w-56,17);" +
                "if(el){if(el.tagName!=='BUTTON'){var b=el.closest('button');if(b){b.click();return 'PT';}}" +
                "el.click();return 'PT';}" +
                "return 'NF';})()"
            evalJS(js, timeout: 3.0) { r in
                self.log("STEP \(idx) [\(t.label)] expand=\(r ?? "TIMEOUT")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // 底部面板展开后探测一次, 确认面板状态
                    self.evalJS("(function(){var es=[].slice.call(document.querySelectorAll('button')).filter(function(x){" +
                        "var t=(x.innerText||x.getAttribute('aria-label')||'').trim(); return t.indexOf('源代码管理')>=0||t.indexOf('Source Control')>=0;});" +
                        "return es.length?'GIT_TAB_VISIBLE':'GIT_TAB_HIDDEN';})()", timeout: 3.0) { r2 in
                        self.log("STEP \(idx) [\(t.label)] gitTab=\(r2 ?? "TIMEOUT")")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.runStep(idx + 1) }
                    }
                }
            }
            return
        }

        evalJS(clickScript(t.label), timeout: 3.0) { [weak self] r in
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                            self.evalAsyncJS(kProbeJS, timeout: 4.0) { p2 in
                                self.log("AFTER_RELOAD ping=\(p2 ?? "TIMEOUT")")
                                self.log("ALL_DONE")
                                NSApp.terminate(nil)
                            }
                        }
                        return
                    }
                    // hold 持续探测
                    if t.hold > 0 {
                        let h = t.hold
                        self.holdProbe(seconds: h, at: idx, label: t.label) {
                            self.afterClose(idx, t: t)
                        }
                    } else {
                        self.afterClose(idx, t: t)
                    }
                }
            }
        }
    }

    /// 在 hold 秒内每秒探测一次; 任一探测超时 => 卡死
    private func holdProbe(seconds: Double, at idx: Int, label: String, onDone: @escaping () -> Void) {
        var remaining = seconds
        func tick() {
            if remaining <= 0 { onDone(); return }
            self.evalAsyncJS(kProbeJS, timeout: 3.5) { p in
                let pv = p ?? "TIMEOUT-卡死!"
                self.log("HOLD \(Int(seconds - remaining + 1))s [\(label)] ping=\(pv)")
                if p == nil {
                    self.log("FREEZE_DETECTED during HOLD at STEP \(idx) [\(label)]")
                    self.webView.reload()
                    self.log("NATIVE_RELOAD sent")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                        self.evalAsyncJS(kProbeJS, timeout: 4.0) { p2 in
                            self.log("AFTER_RELOAD ping=\(p2 ?? "TIMEOUT")")
                            self.log("ALL_DONE")
                            NSApp.terminate(nil)
                        }
                    }
                    return
                }
                remaining -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { tick() }
            }
        }
        tick()
    }

    private func afterClose(_ idx: Int, t: (label: String, close: String, hold: Double)) {
        if t.close == "esc" {
            evalJS("(function(){var d=document.querySelector('[role=dialog],[class*=overlay],[class*=Overlay]');" +
                "var b=d&&[].slice.call(d.querySelectorAll('button')).find(function(x){return (x.innerText||'').trim()==='关闭';});" +
                "if(b){b.click();return 'CLOSED';}" +
                "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return 'ESC';})()",
                timeout: 2.0) { _ in
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