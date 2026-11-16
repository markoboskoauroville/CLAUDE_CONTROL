// Claude Control (Mantra): one play/pause button in the menu bar for every Claude Code session and every tool that runs for it.
// Marko, 16.11.2026: "Please build a menu bar item which is going to be run as soon as any of Claude's code sessions are running,
// which is called Claude Control. And I can pause all the tasks which are happening and also resume them. Play pause button, simple."
import AppKit

let VERSION = 4
let APP_NAME = "Claude Control (Mantra)"

@main
struct Main {
    static func main() {
        let a = CommandLine.arguments
        if a.count > 1, ["pause", "resume", "status"].contains(a[1]) { CLI.run(a); exit(0) }      // claudectl: the same logic, no window
        if a.count > 1, a[1] == "version" { print("v\(VERSION)"); exit(0) }
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)          // menu bar only, no Dock icon, no window
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let band = StatusBand(frame: .zero)
    private var timer: Timer?
    private var sessions: [Session] = []
    private var tools: [ToolState] = []
    private var paused = false
    private var since: Double?
    private var emptySince: Date?
    private var busy = false
    private var visObs: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ n: Notification) {
        let key = "NSStatusItem Preferred Position ClaudeControlBar"
        if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(2, forKey: key) }
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible ClaudeControlBar")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ClaudeControlBar"
        item.isVisible = true
        visObs = item.observe(\.isVisible, options: [.new]) { i, _ in if !i.isVisible { DispatchQueue.main.async { i.isVisible = true } } }
        if let b = item.button {
            b.setAccessibilityLabel("Claude Control (Mantra): play pause")
            b.addSubview(band)
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        HoverCard.attach(to: item) { [weak self] in
            guard let self else { return HoverCard.Content(name: "Claude Control (Mantra)", what: "", state: "") }
            let lines = self.stateLines()
            return HoverCard.Content(name: "Claude Control (Mantra)", what: "Pauses and resumes all Claude Code sessions and tools",
                state: self.sessionsPaused ? "CLAUDE PAUSED" : (self.sessions.isEmpty ? "NO CLAUDE SESSION" : "CLAUDE RUNNING"),
                stateColor: self.sessionsPaused ? .systemOrange : .systemGreen, lines: lines)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        Updater.checkAtStart()
    }

    // a left click is the play/pause; right click or option-click opens the small menu
    @objc func clicked(_ s: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.option) == true { showMenu(); return }
        toggle()
    }

    func toggle() { sessionsPaused ? doResume() : doPause() }
    var sessionsPaused: Bool { sessions.contains { $0.paused } || (sessionsStateFile && !sessions.isEmpty) }
    private var sessionsStateFile = false
    @objc func doPause() { work { _ = Core.pauseAll() } }
    @objc func doResume() { work { _ = Core.resumeAll() } }
    private func work(_ f: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global().async { f(); DispatchQueue.main.async { self.busy = false; self.refresh() } }
    }

    func stateLines() -> [String] {
        let n = sessions.count
        var l = ["Claude: " + (n == 0 ? "NO SESSION" : (sessionsPaused ? "PAUSED" : "RUNNING") + " (\(n) session\(n == 1 ? "" : "s"))")]
        for t in tools { l.append("\(t.name): \(t.state.uppercased())") }
        if paused, let sc = since { l.append("Paused \(Int(Date().timeIntervalSince1970 - sc) / 60) min") }
        return l
    }
    @objc func menuClaude() { work { if self.sessionsPaused { _ = Core.resumeSessions() } else { _ = Core.pauseSessions() } } }
    @objc func menuTool(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let t = tools.first(where: { $0.name == n }) else { return }
        work { t.state == "paused" ? Core.resumeTool(n) : Core.pauseTool(n) }
    }
    private func showMenu() {
        let m = NSMenu()
        let n = sessions.count
        m.addItem(withTitle: stateLines()[0], action: nil, keyEquivalent: "")
        if n > 0 { let i = NSMenuItem(title: sessionsPaused ? "   Resume Claude" : "   Pause Claude", action: #selector(menuClaude), keyEquivalent: ""); i.target = self; m.addItem(i) }
        for t in tools {
            m.addItem(withTitle: "\(t.name): \(t.state.uppercased())", action: nil, keyEquivalent: "")
            if t.state != "unreachable" {
                let i = NSMenuItem(title: t.state == "paused" ? "   Resume \(t.name)" : "   Pause \(t.name)", action: #selector(menuTool(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = t.name; m.addItem(i)
            }
        }
        if paused, let s = since, Date().timeIntervalSince1970 - s > Core.warnAfter {
            m.addItem(.separator())
            m.addItem(withTitle: "Paused over 10 min: API connections may time out;", action: nil, keyEquivalent: "")
            m.addItem(withTitle: "sessions will retry or report errors.", action: nil, keyEquivalent: "")
        }
        m.addItem(.separator())
        let p = NSMenuItem(title: "Pause all", action: #selector(doPause), keyEquivalent: ""); p.target = self; m.addItem(p)
        let r = NSMenuItem(title: "Resume all", action: #selector(doResume), keyEquivalent: ""); r.target = self; m.addItem(r)
        if n > 0 {
            m.addItem(.separator())
            m.addItem(withTitle: "Claude Code sessions", action: nil, keyEquivalent: "")
            for s in sessions { m.addItem(withTitle: "   \(s.paused ? "PAUSED" : "RUNNING")  \((s.folder as NSString).lastPathComponent)  ·  \(s.procs)", action: nil, keyEquivalent: "") }
        }
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"); q.target = self; m.addItem(q)
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }
    @objc func quit() { NSApp.terminate(nil) }

    // every 3 s, in the background: who runs, what is paused; quits 60 s after the last session, never while paused
    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let s = Core.sessions(), t = Core.toolStates(), pausedNow = Core.isPaused(), since = Core.pausedSince()
            DispatchQueue.main.async {
                if self.busy { return }
                self.sessions = s; self.tools = t; self.since = since; self.sessionsStateFile = pausedNow
                self.paused = pausedNow || t.contains { $0.state == "paused" }
                if s.isEmpty && pausedNow { Core.saveState(nil); self.paused = t.contains { $0.state == "paused" } }  // the paused sessions are gone
                self.draw()
                if s.isEmpty && !self.paused {
                    if self.emptySince == nil { self.emptySince = Date() }
                    else if Date().timeIntervalSince(self.emptySince!) > 60 { NSApp.terminate(nil) }
                } else { self.emptySince = nil }
            }
        }
    }

    private func draw() {
        let n = sessions.count
        let long = paused && since.map { Date().timeIntervalSince1970 - $0 > Core.warnAfter } == true
        let green = NSColor(red: 0.2, green: 0.82, blue: 0.48, alpha: 1), amber = NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 1)
        var seg: [(String, NSColor)]
        if n == 0 { seg = [("CLAUDE NO SESSION", NSColor(white: 0.7, alpha: 1))] }
        else if sessionsPaused { seg = [("CLAUDE ❚❚ PAUSED" + (long ? " !" : ""), amber)] }
        else { seg = [("CLAUDE ▶ RUNNING", green)] }
        let claudePaused = n > 0 && sessionsPaused
        for t in tools where t.state != "unreachable" && (n == 0 ? t.state == "paused" : (t.state == "paused") != claudePaused) {
            seg.append((" · ", NSColor(white: 0.7, alpha: 1)))
            seg.append(t.state == "paused" ? ("\(Core.shortName(t.name)) ❚❚ PAUSED", amber) : ("\(Core.shortName(t.name)) ▶ RUNNING", green))
        }
        band.segments = seg
        guard let button = item.button else { return }
        let w = band.wantedWidth
        if abs(item.length - (w + 6)) > 0.5 { item.length = w + 6 }
        let h = max(18, button.bounds.height - 4)
        band.frame = NSRect(x: 3, y: (button.bounds.height - h) / 2, width: w, height: h)
        button.toolTip = sessionsPaused ? "Paused. Click to resume all." : "Click to pause all Claude Code sessions and tools. Right click: menu."
    }
}
