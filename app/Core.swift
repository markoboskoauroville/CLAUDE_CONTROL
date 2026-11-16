// Core.swift: the one logic of Claude Control, used by the menu-bar app and by the CLI (`claudectl`, which runs this same binary).
// Marko, 16.11.2026: "a menu bar item ... as soon as any of Claude's code sessions are running ... I can pause all the tasks
// which are happening and also resume them. Play pause button, simple." And: "All our tools need to be paused at the same time."
//
// PAUSE ALL = (1) every registered tool (~/.config/claude-control/tools.json: Macro Recorder, Queen, ...) through its own
// pause API; (2) every Claude Code session and everything it started: SIGSTOP, children first, then parents.
// RESUME = SIGCONT parents first, then the tools' resume. The stopped pids are kept in
// ~/Library/Application Support/Claude Control/paused.json so a resume after an app restart continues exactly those.
import Foundation

struct Proc { let pid: Int32; let ppid: Int32; let stat: String; let cmd: String }
struct Stopped: Codable { var pid: Int32; var ppid: Int32; var depth: Int; var cmd: String; var root: Bool }
struct PauseState: Codable { var since: Double; var items: [Stopped] }
struct Session { let pid: Int32; let folder: String; let paused: Bool; let procs: Int }
struct ToolAction: Codable { var cmd: [String]?; var method: String?; var url: String?; var jsonField: String?; var pausedWhen: String? }
struct Tool: Codable { var name: String; var pause: ToolAction; var resume: ToolAction; var status: ToolAction }
struct ToolState { let name: String; let state: String }     // "paused" | "running" | "unreachable"

enum Core {
    /// CLAUDECTL_TESTDIR: tests only. Only `claude`-named processes whose argv0 lives under that folder count, and the state file lives there.
    static let testDir = ProcessInfo.processInfo.environment["CLAUDECTL_TESTDIR"]
    static var supportDir: URL {
        if let t = testDir { return URL(fileURLWithPath: t) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude Control")
    }
    static var stateURL: URL { supportDir.appendingPathComponent("paused.json") }
    static var toolsURL: URL {
        if let t = testDir { return URL(fileURLWithPath: t).appendingPathComponent("tools.json") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-control/tools.json")
    }
    static let warnAfter: Double = 600       // 10 minutes

    // ------------------------------------------------------------ processes
    @discardableResult
    static func sh(_ exe: String, _ args: [String], timeout: Double = 8) -> (Int32, String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "") }
        var killed = false
        let t = DispatchWorkItem { killed = true; p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: t)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); t.cancel()
        return (killed ? 124 : p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func processes() -> [Proc] {
        let (_, text) = sh("/bin/ps", ["-axww", "-o", "pid=,ppid=,stat=,command="])
        var list: [Proc] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let pp = Int32(parts[1]) else { continue }
            list.append(Proc(pid: pid, ppid: pp, stat: String(parts[2]), cmd: String(parts[3])))
        }
        return list
    }

    static func argv0(_ cmd: String) -> String { String(cmd.split(separator: " ", maxSplits: 1).first ?? "") }

    /// A Claude Code CLI: argv0 is a file named exactly `claude` (not inside an .app), or node running @anthropic-ai/claude-code.
    static func isClaude(_ p: Proc) -> Bool {
        let a = argv0(p.cmd)
        let base = (a as NSString).lastPathComponent
        if let t = testDir { return base == "claude" && a.hasPrefix(t) }
        if p.cmd.contains(".app/") { return false }
        if base == "claude" { return true }
        if base == "node" && p.cmd.contains("@anthropic-ai/claude-code") { return true }
        return false
    }

    /// Never stopped, with everything below them: this app, the CLI, the voice server, Macro Recorder's app, Talk Mode, Voice to Text,
    /// Firefox, Tailscale, Connection Keeper.
    static let protectedWords = ["claude control", "claudecontrol", "claudectl", "mantra_voice", "voice engine", "macro recorder", "macrorecorder",
                                 "talk mode", "talkmode", "voice to text", "firefox", "tailscale", "connection keeper", "connection-keeper",
                                 "connectionkeeper", "chatd.py", "hammerspoon"]
    static func isProtected(_ p: Proc, voicePids: Set<Int32>) -> Bool {
        if p.pid == getpid() || voicePids.contains(p.pid) { return true }
        let c = p.cmd.lowercased()
        return protectedWords.contains { c.contains($0) }
    }
    static func voiceServerPids() -> Set<Int32> {
        if testDir != nil { return [] }
        let (_, o) = sh("/usr/sbin/lsof", ["-ti", "tcp:8837", "-sTCP:LISTEN"], timeout: 4)
        return Set(o.split(separator: "\n").compactMap { Int32($0) })
    }

    struct Tree { let roots: [Proc]; let members: [(Proc, Int, Bool)] }   // (process, depth, isRoot), protected subtrees left out
    static func scan() -> Tree {
        let all = processes()
        var kids: [Int32: [Proc]] = [:]
        for p in all { kids[p.ppid, default: []].append(p) }
        let voice = voiceServerPids()
        let roots = all.filter { isClaude($0) && !isProtected($0, voicePids: voice) }
        var seen = Set<Int32>(), members: [(Proc, Int, Bool)] = []
        func walk(_ p: Proc, _ d: Int, _ root: Bool) {
            if seen.contains(p.pid) || isProtected(p, voicePids: voice) { return }
            seen.insert(p.pid); members.append((p, d, root))
            for c in kids[p.pid] ?? [] { walk(c, d + 1, false) }
        }
        for r in roots { walk(r, 0, true) }
        return Tree(roots: roots, members: members)
    }

    static func cwd(_ pid: Int32) -> String {
        if testDir != nil { return "test" }
        let (_, o) = sh("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", String(pid), "-Fn"], timeout: 4)
        for l in o.split(separator: "\n") where l.hasPrefix("n") { return String(l.dropFirst()) }
        return "?"
    }

    // ------------------------------------------------------------ state file
    static func loadState() -> PauseState? {
        guard let d = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(PauseState.self, from: d)
    }
    static func saveState(_ s: PauseState?) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let s = s, !s.items.isEmpty, let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: stateURL) }
    }
    static func alive(_ s: Stopped) -> Bool {
        let (rc, o) = sh("/bin/ps", ["-ww", "-p", String(s.pid), "-o", "command="], timeout: 3)
        return rc == 0 && o.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(String(s.cmd.prefix(120)))
    }

    // ------------------------------------------------------------ pause / resume of the Claude sessions
    @discardableResult
    static func pauseSessions() -> Int {
        var st = loadState() ?? PauseState(since: Date().timeIntervalSince1970, items: [])
        var count = 0
        for pass in 0..<4 {
            let t = scan()
            let known = Set(st.items.map { $0.pid })
            let fresh = t.members.filter { !known.contains($0.0.pid) && !$0.0.stat.hasPrefix("T") }
                                 .sorted { $0.1 > $1.1 }          // deepest first: children before parents
            if fresh.isEmpty { break }
            for (p, d, root) in fresh {
                if kill(p.pid, SIGSTOP) == 0 {
                    st.items.append(Stopped(pid: p.pid, ppid: p.ppid, depth: d, cmd: String(p.cmd.prefix(300)), root: root)); count += 1
                }
            }
            saveState(st)
            if pass < 3 { usleep(150_000) }
        }
        saveState(st)
        return count
    }

    @discardableResult
    static func resumeSessions() -> Int {
        guard let st = loadState() else { return 0 }
        var n = 0
        for s in st.items.sorted(by: { $0.depth < $1.depth }) where alive(s) {     // parents first
            if kill(s.pid, SIGCONT) == 0 { n += 1 }
        }
        saveState(nil)
        return n
    }

    // ------------------------------------------------------------ the registered tools (Macro Recorder, Queen, ...)
    static func loadTools() -> [Tool] {
        guard let d = try? Data(contentsOf: toolsURL) else { return [] }
        return (try? JSONDecoder().decode([Tool].self, from: d)) ?? []
    }
    static func run(_ a: ToolAction) -> String? {
        if let c = a.cmd, let exe = c.first {
            let path = exe.hasPrefix("/") ? exe : "/usr/bin/env"
            let (rc, o) = sh(path, exe.hasPrefix("/") ? Array(c.dropFirst()) : c, timeout: 8)
            return rc == 0 ? o : nil
        }
        if let u = a.url {
            let (rc, o) = sh("/usr/bin/curl", ["-s", "-m", "5", "-X", a.method ?? "GET", u], timeout: 8)
            return rc == 0 ? o : nil
        }
        return nil
    }
    static func toolState(_ t: Tool) -> ToolState {
        guard let o = run(t.status) else { return ToolState(name: t.name, state: "unreachable") }
        if let f = t.status.jsonField {
            if let j = try? JSONSerialization.jsonObject(with: Data(o.utf8)) as? [String: Any], let b = j[f] as? Bool {
                return ToolState(name: t.name, state: b ? "paused" : "running")
            }
            return ToolState(name: t.name, state: "unreachable")
        }
        let want = t.status.pausedWhen ?? "paused"
        return ToolState(name: t.name, state: o.trimmingCharacters(in: .whitespacesAndNewlines) == want ? "paused" : "running")
    }
    static func toolStates() -> [ToolState] { loadTools().map(toolState) }

    // ------------------------------------------------------------ all together
    static func pauseAll() -> String {
        var notes: [String] = []
        for t in loadTools() { notes.append("\(t.name): " + (run(t.pause) != nil ? "paused" : "NOT REACHED")) }
        let n = pauseSessions()
        notes.append("Claude sessions: \(n) process(es) stopped")
        return notes.joined(separator: "\n")
    }
    static func resumeAll() -> String {
        var notes: [String] = []
        let n = resumeSessions()
        notes.append("Claude sessions: \(n) process(es) continued")
        for t in loadTools() { notes.append("\(t.name): " + (run(t.resume) != nil ? "resumed" : "NOT REACHED")) }
        return notes.joined(separator: "\n")
    }

    static func sessions() -> [Session] {
        let t = scan()
        let stopped = Set((loadState()?.items ?? []).map { $0.pid })
        var below: [Int32: Int] = [:]
        var kids: [Int32: [Int32]] = [:]
        for (p, _, _) in t.members { kids[p.ppid, default: []].append(p.pid) }
        func count(_ pid: Int32) -> Int { 1 + (kids[pid] ?? []).reduce(0) { $0 + count($1) } }
        for r in t.roots { below[r.pid] = count(r.pid) }
        return t.roots.map { r in
            Session(pid: r.pid, folder: cwd(r.pid), paused: stopped.contains(r.pid) || r.stat.hasPrefix("T"), procs: below[r.pid] ?? 1)
        }
    }
    static func pausedSince() -> Double? { loadState()?.since }
    static func isPaused() -> Bool { loadState() != nil }
    static func isAnyPaused() -> Bool { isPaused() || toolStates().contains { $0.state == "paused" } }

    static func statusText() -> String {
        var out: [String] = []
        let ss = sessions()
        let paused = isPaused()
        out.append((paused ? "PAUSED" : "RUNNING") + " · \(ss.count) Claude Code session\(ss.count == 1 ? "" : "s")")
        for s in ss { out.append("  \(s.paused ? "PAUSED " : "RUNNING") pid \(s.pid)  \(s.folder)  (\(s.procs) process\(s.procs == 1 ? "" : "es"))") }
        for t in toolStates() { out.append("  \(t.state.uppercased())  \(t.name)") }
        if let since = pausedSince(), Date().timeIntervalSince1970 - since > warnAfter {
            out.append("WARNING: paused for \(Int((Date().timeIntervalSince1970 - since) / 60)) min. API connections may time out; sessions will retry or report errors.")
        }
        return out.joined(separator: "\n")
    }
}

enum CLI {
    static func run(_ a: [String]) {
        switch a[1] {
        case "pause": print(Core.pauseAll())
        case "resume": print(Core.resumeAll())
        case "status": print(Core.statusText())
        default: print("claudectl pause | resume | status")
        }
    }
}
