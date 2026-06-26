import Cocoa

// One session's status, parsed from ~/.claude/statusbar/sessions.d/<id>.json.
struct SessionState {
    var state: String
    var label: String
    var project: String
    var title: String       // Claude Code's ai-title (the terminal-tab name); falls back to project
    var sessionId: String
    var transcript: String
    var startedAt: Double
    var ts: Double
    var name: String { !title.isEmpty ? title : (project.isEmpty ? "session" : project) }
}

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/sessions.d")
    let claudeDesktopBundleID = "com.anthropic.claudefordesktop"
    let terminalBundleID = "com.apple.Terminal"
    let ghosttyBundleID = "com.mitchellh.ghostty"

    var lastSig = ""           // signature of sessions.d (names + mtimes); reload only on change
    var pollTimer: Timer?
    var animTimer: Timer?
    var frameIdx = 0
    var menuRefreshTimer: Timer?                        // ticks the open menu's session clocks
    var menuRowItems: [(NSMenuItem, SessionState)] = [] // open-menu rows, for the live refresh

    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
    let staleAfter: TimeInterval = 900  // a session not seen in 15 min is recovered to idle AND
                                        // dropped from the menu, so a crashed/closed tab can't linger
    let thinkingIdleAfter: TimeInterval = 30 // a "thinking" session whose transcript has been quiet
                                             // this long really finished (its Stop hook never fired)

    var rawSessions: [SessionState] = []      // last parsed snapshot of sessions.d/*.json
    var displaySessions: [SessionState] = []  // active (working/permission), most-recent first
    var activeCount = 0
    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil

    let brand = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #d97757, Anthropic's official "Orange" accent
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    let frames: [NSImage] = StatusController.loadFrames()
    let spriteFPS: Double = 9 // tune: 8 frames per loop -> ~0.9s/cycle

    enum AnimStyle: String { case web, code, crab }
    var animStyle: AnimStyle = .web
    // Which session leads the menu bar when several are active: the most-recently-active one
    // (per issue #8), or any awaiting permission first (so a blocked session is never hidden).
    enum PriorityMode: String { case recent, permission }
    var priorityMode: PriorityMode = .recent
    var showTimer = false
    var iconSystem = false // false = brand Orange; true = adaptive black/white (template image)
    var playCompletionSound = false // chime when a turn longer than ~1 min finishes
    var showTerminalApps = false    // off by default; reveals Open Terminal / Open Ghostty menu items
    lazy var completionSound: NSSound? = {
        guard let p = Bundle.main.path(forResource: "completion", ofType: "mp3"),
              let s = NSSound(contentsOfFile: p, byReference: true) else { return nil }
        s.volume = 0.7 // the clip is loud at full system volume; play it a bit softer
        return s
    }()
    var turnStarts: [String: Double] = [:]  // per-session turn start, for the 1-min completion chime
    var workingLast: Set<String> = []       // sessions working on the previous tick (chime edge-detect)
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    let codeGlyphs = ["✻", "✽", "✶", "✳", "✢"]
    let codePeaks: [CGFloat] = [1.0, 1.0, 1.0, 1.0, 1.0]
    let codeDip: CGFloat = 0.14 // glyph shrinks to this at each swap
    let codeSub = 18            // sub-frames per glyph (tween smoothness)
    let codeCycle: Double = 3.8 // seconds for the full loop (lower = faster)
    lazy var codeGlyphMasks: [NSImage] = codeGlyphs.map { StatusController.glyphMask($0) }
    let crabFPS: Double = 12.5 // matches the source GIF's 0.08s frame delay
    lazy var crabFrames: [NSImage] = StatusController.decodePNGs(clawdCrabFramePNGs)
    var fps: Double {
        switch animStyle {
        case .web: return spriteFPS
        case .code: return Double(codeGlyphs.count * codeSub) / codeCycle
        case .crab: return crabFPS
        }
    }
    var frameCount: Int {
        switch animStyle {
        case .web: return max(1, frames.count)
        case .code: return codeGlyphs.count * codeSub
        case .crab: return max(1, crabFrames.count)
        }
    }

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if d.object(forKey: "completionSound") != nil { playCompletionSound = d.bool(forKey: "completionSound") }
        if d.object(forKey: "showTerminalApps") != nil { showTerminalApps = d.bool(forKey: "showTerminalApps") }
        if let s = d.string(forKey: "animStyle"), let st = AnimStyle(rawValue: s) { animStyle = st }
        if let p = d.string(forKey: "priorityMode"), let pm = PriorityMode(rawValue: p) { priorityMode = pm }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
        ensureHooksInstalled()
        checkForUpdate()
    }

    // Re-runs on first install AND on every version change, so upgrades pick up hook
    // changes and retire old artifacts. See CLAUDE.md "ensureHooksInstalled" for why.
    func ensureHooksInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard d.string(forKey: "installedVersion") != current,
              let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        DispatchQueue.global().async {
            guard let node = Self.locateNode() else {
                NSLog("ClaudeStatusBar: could not find node; hooks not installed (will retry next launch)")
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: node)
            task.arguments = [installer]
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { UserDefaults.standard.set(current, forKey: "installedVersion") }
        }
    }

    // `/bin/zsh -lc node` saw only the login PATH, missing nvm/fnm set in .zshrc.
    static func locateNode() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: >) { candidates.append("\(nvmDir)/\(v)/bin/node") }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }

        for args in [["-ilc", "command -v node"], ["-lc", "command -v node"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: update check

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    let releaseAPIURL = "https://api.github.com/repos/m1ckc3s/claude-status-bar/releases/latest"
    let releasePageURL = "https://github.com/m1ckc3s/claude-status-bar/releases/latest"

    // Once/day: cache GitHub's latest release tag in UserDefaults. Nothing sent to us.
    // See CLAUDE.md "Update check" for the privacy/behavior notes.
    func checkForUpdate() {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if now - d.double(forKey: "lastUpdateCheck") < 86400 { return }
        guard let url = URL(string: releaseAPIURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("ClaudeStatusBar", forHTTPHeaderField: "User-Agent") // GitHub API requires a UA
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(ver, forKey: "latestVersion")
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        }.resume()
    }

    // Numeric component-wise compare so "0.0.10" > "0.0.9".
    func versionIsNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func openLatestRelease() {
        if let url = URL(string: releasePageURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        checkForUpdate() // refreshes the update cache for next open (gated to once a day)

        let openItem = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Terminal launchers are off by default (the original is desktop-app oriented); the
        // "Show terminal launchers" toggle in Options reveals them for terminal-centric users.
        if showTerminalApps {
            let termItem = NSMenuItem(title: "Open Terminal", action: #selector(openTerminal), keyEquivalent: "")
            termItem.target = self
            menu.addItem(termItem)
            // Only offer Ghostty if it's actually installed.
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleID) != nil {
                let ghosttyItem = NSMenuItem(title: "Open Ghostty", action: #selector(openGhostty), keyEquivalent: "")
                ghosttyItem.target = self
                menu.addItem(ghosttyItem)
            }
        }
        menu.addItem(.separator())

        // Sessions roster: every recent session (active first, then idle), most-recent within each.
        menuRowItems.removeAll()
        if !displaySessions.isEmpty {
            menu.addItem(header(displaySessions.count >= 2 ? "Sessions · \(displaySessions.count)" : "Sessions"))
            let now = Date().timeIntervalSince1970
            for s in displaySessions {
                let it = sessionRow(s, now: now)
                menuRowItems.append((it, s)) // remember rows so the open menu can tick them live
                menu.addItem(it)
            }
            menu.addItem(.separator())
        }

        menu.addItem(header("Options"))

        let timerItem = NSMenuItem(title: "Show timer", action: #selector(toggleTimer), keyEquivalent: "")
        timerItem.target = self
        timerItem.state = showTimer ? .on : .off
        menu.addItem(timerItem)

        let termToggle = NSMenuItem(title: "Show terminal apps", action: #selector(toggleTerminalApps), keyEquivalent: "")
        termToggle.target = self
        termToggle.state = showTerminalApps ? .on : .off
        menu.addItem(termToggle)

        let soundItem = NSMenuItem(title: "Play Completion Sound", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = playCompletionSound ? .on : .off
        if #available(macOS 14.0, *) { soundItem.badge = NSMenuItemBadge(string: "1m+") }
        menu.addItem(soundItem)

        menu.addItem(.separator())
        menu.addItem(header("Priority"))
        for (mode, name) in [(PriorityMode.recent, "Most recent"), (PriorityMode.permission, "Awaiting permission")] {
            let it = NSMenuItem(title: name, action: #selector(choosePriority(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = priorityMode == mode ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(header("Animation"))
        for (style, name) in [(AnimStyle.web, "Claude Spark"), (AnimStyle.code, "Claude Code"), (AnimStyle.crab, "Crab Walking")] {
            let it = NSMenuItem(title: name, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = animStyle == style ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(header("Color"))
        for (sys, name) in [(false, "Orange"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: ""))
        if let latest = UserDefaults.standard.string(forKey: "latestVersion"), versionIsNewer(latest, than: currentVersion) {
            let up = NSMenuItem(title: "Update available", action: #selector(openLatestRelease), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
        }
        let q = NSMenuItem(title: "Quit Claude Status Bar", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    // NSMenu builds its items once on open and never rebuilds while shown, so the per-session
    // clocks (and the bar clock) would freeze. Tick them every second while the menu is open.
    func menuWillOpen(_ menu: NSMenu) {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshOpenMenu() }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking) // status-item menus track in this mode
        menuRefreshTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate(); menuRefreshTimer = nil
        menuRowItems.removeAll()
    }

    func refreshOpenMenu() {
        let now = Date().timeIntervalSince1970
        for (item, s) in menuRowItems { item.attributedTitle = sessionRowTitle(s, now: now) }
        applyTitle() // keep the menu-bar clock live while the menu is open, too
        statusItem.button?.needsDisplay = true
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // One "project · verb  1m 2s" row, with a leading state-colored dot that echoes the
    // menu-bar icon. action:nil => auto-disabled + dimmed, matching the Version row.
    func sessionRow(_ s: SessionState, now: Double) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let working = s.state == "thinking" || s.state == "tool"
        let isPerm = s.state == "permission"
        // Dot echoes the menu-bar language: amber = awaiting permission, orange = working, muted = idle.
        let dotColor: NSColor = isPerm ? amber : (working ? (iconColor ?? .secondaryLabelColor) : .tertiaryLabelColor)
        it.image = sessionDot(dotColor)
        it.attributedTitle = sessionRowTitle(s, now: now)
        return it
    }

    // The row's text (name · verb · elapsed clock). Split out so the OPEN menu can re-render the
    // live clock every second — NSMenu builds its items only on open, so without this the timers
    // freeze the moment you click the menu.
    func sessionRowTitle(_ s: SessionState, now: Double) -> NSAttributedString {
        let working = s.state == "thinking" || s.state == "tool"
        let isPerm = s.state == "permission"
        let line = NSMutableAttributedString()
        let name = s.name.count > 34 ? String(s.name.prefix(33)) + "…" : s.name
        line.append(NSAttributedString(string: name,
            attributes: [.foregroundColor: NSColor.labelColor]))
        let verb = isPerm ? "Awaiting permission" : (working ? (s.label.isEmpty ? "Working" : s.label) : "Idle")
        line.append(NSAttributedString(string: "  ·  \(verb)",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        if working, s.startedAt > 0 { // only a running session shows the elapsed clock
            let secs = max(0, Int(now - s.startedAt)), m = secs / 60, sec = secs % 60
            let clk = m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
            line.append(NSAttributedString(string: "   \(clk)", attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
            ]))
        }
        return line
    }

    // Small filled dot (amber = permission, orange/system = working) shown before a session row.
    func sessionDot(_ color: NSColor) -> NSImage {
        let s: CGFloat = 10, d: CGFloat = 7
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc func quit() { NSApp.terminate(nil) }

    func openApp(bundleID: String) {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: bundleID) {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    @objc func openClaude()   { openApp(bundleID: claudeDesktopBundleID) }
    @objc func openTerminal() { openApp(bundleID: terminalBundleID) }
    @objc func openGhostty()  { openApp(bundleID: ghosttyBundleID) }

    @objc func toggleTimer() {
        showTimer.toggle()
        UserDefaults.standard.set(showTimer, forKey: "showTimer")
        applyTitle()
    }

    @objc func toggleSound() {
        playCompletionSound.toggle()
        UserDefaults.standard.set(playCompletionSound, forKey: "completionSound")
    }

    @objc func toggleTerminalApps() {
        showTerminalApps.toggle()
        UserDefaults.standard.set(showTerminalApps, forKey: "showTerminalApps")
    }

    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        aggregate() // re-render the current state in the new color
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = AnimStyle(rawValue: raw) else { return }
        animStyle = st
        UserDefaults.standard.set(raw, forKey: "animStyle")
        animTimer?.invalidate(); animTimer = nil // recreate at the new style's fps
        frameIdx = 0
        aggregate()
    }

    @objc func choosePriority(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pm = PriorityMode(rawValue: raw) else { return }
        priorityMode = pm
        UserDefaults.standard.set(raw, forKey: "priorityMode")
        aggregate()
    }

    // MARK: state polling

    func tick() {
        checkLifecycle()
        let sig = sessionsSignature()
        if sig != lastSig { lastSig = sig; rawSessions = loadSessions() }
        // aggregate() runs every tick (not just on change): the transcript-marker recovery and
        // the live elapsed clock advance on time, not on a session-file write.
        aggregate()
    }

    // "Hash of dir listing + per-file mtime": cheap signature so we re-read sessions.d only
    // when a session file appears, disappears, or changes. *.tmp atomic-write files are ignored.
    func sessionsSignature() -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return "" }
        var parts: [String] = []
        for n in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let p = (sessionsDir as NSString).appendingPathComponent(n)
            let m = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(n):\(m)")
        }
        return parts.joined(separator: "|")
    }

    func loadSessions() -> [SessionState] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }
        var out: [SessionState] = []
        for n in names where n.hasSuffix(".json") {
            let p = (sessionsDir as NSString).appendingPathComponent(n)
            guard let data = fm.contents(atPath: p),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            out.append(SessionState(
                state: o["state"] as? String ?? "idle",
                label: o["label"] as? String ?? "",
                project: o["project"] as? String ?? "",
                title: o["title"] as? String ?? "",
                sessionId: o["sessionId"] as? String ?? n,
                transcript: o["transcript"] as? String ?? "",
                startedAt: (o["startedAt"] as? NSNumber)?.doubleValue ?? 0,
                ts: (o["ts"] as? NSNumber)?.doubleValue ?? 0))
        }
        return out
    }

    // Per-session recovery. The Stop hook fires on normal completion but NOT on an Esc interrupt,
    // a denied permission prompt, OR (commonly) a turn that answers without running any tool — so
    // a session can sit frozen on "thinking" with no event to clear it. Recover three ways:
    //  1. absolute 15-min staleness net (covers force-quit / any frozen state),
    //  2. transcript marker "interrupted by user" (Esc / denied prompt),
    //  3. a "thinking" session whose transcript has gone quiet for thinkingIdleAfter — real thinking
    //     streams continuously, so a silent transcript means the turn ended with no Stop hook. ("tool"
    //     is exempt: a long-running command legitimately writes nothing while it runs.)
    func recover(_ s: SessionState) -> SessionState {
        var s = s
        guard ["thinking", "tool", "permission"].contains(s.state) else { return s }
        let now = Date().timeIntervalSince1970
        if now - s.ts > staleAfter { s.state = "idle"; s.label = ""; return s }
        if s.state == "thinking", !s.transcript.isEmpty,
           let attrs = try? FileManager.default.attributesOfItem(atPath: s.transcript),
           let m = attrs[.modificationDate] as? Date,
           now - m.timeIntervalSince1970 > thinkingIdleAfter {
            s.state = "idle"; s.label = ""; return s
        }
        if let last = lastLine(ofFileAt: s.transcript), last.contains("interrupted by user") {
            s.state = "idle"; s.label = ""
        }
        return s
    }

    // Aggregate every session into one menu-bar presentation.
    func aggregate() {
        let now = Date().timeIntervalSince1970
        let sessions = rawSessions.map(recover)

        let working = sessions.filter { $0.state == "thinking" || $0.state == "tool" }
        func isActive(_ s: SessionState) -> Bool { ["thinking", "tool", "permission"].contains(s.state) }
        // "Active" = working or awaiting permission (the attention-worthy states); drives the bar + count.
        let active = sessions.filter(isActive).sorted { ($0.ts, $0.startedAt) > ($1.ts, $1.startedAt) }
        activeCount = active.count

        // Menu roster: EVERY session seen in the last `staleAfter` seconds (idle included), active
        // ones first then most-recent idle. The age filter drops a crashed/closed tab so it can't
        // linger as a ghost row.
        displaySessions = sessions
            .filter { now - $0.ts < staleAfter }
            .filter { isActive($0) || !$0.title.isEmpty || !$0.project.isEmpty } // hide nameless just-started sessions
            .sorted { (isActive($0) ? 1 : 0, $0.ts) > (isActive($1) ? 1 : 0, $1.ts) }

        // Completion chime: per-session, fires once when a turn that ran >= 1 min leaves "working".
        if playCompletionSound {
            let nowWorking = Set(working.map { $0.sessionId })
            for w in working where w.startedAt > 0 { turnStarts[w.sessionId] = w.startedAt }
            for id in workingLast where !nowWorking.contains(id) {
                if let start = turnStarts[id], now - start >= 60 { completionSound?.play() }
                turnStarts[id] = nil
            }
            workingLast = nowWorking
        } else {
            turnStarts.removeAll(); workingLast.removeAll()
        }

        // Which session leads the bar (Priority setting):
        //  • .recent — the most-recently-active session, whatever its state (per issue #8). A
        //    fresh permission request briefly leads and flashes "Awaiting permission"; as soon as
        //    you work elsewhere that session's ts overtakes it and the bar follows your work.
        //  • .permission — any session awaiting permission wins (most-recent among them), so a
        //    blocked session is never hidden behind one that's merely working.
        // Either way the ×N badge counts active sessions and idle ones stay in the Sessions list.
        let lead = (priorityMode == .permission ? active.first(where: { $0.state == "permission" }) : nil) ?? active.first
        if let lead = lead {
            if lead.state == "permission" {
                render(label: "Awaiting permission", color: amber, animate: false, startedAt: 0, dot: true)
            } else {
                let label = lead.label.isEmpty ? (lead.state == "tool" ? "Working…" : "Thinking…") : lead.label
                render(label: label, color: iconColor, animate: true, startedAt: lead.startedAt)
            }
        } else {
            render(label: "", color: iconColor, animate: false, startedAt: 0) // all idle/done: resting spark
        }
    }

    // MARK: self-quit lifecycle (rationale + warmup-churn history in CLAUDE.md)

    func claudeDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeDesktopBundleID }
    }

    func sessionCount() -> Int {
        // Count every session marker except in-flight *.tmp atomic writes. Legacy empty
        // markers (pre-upgrade) still count, so a pre-existing session keeps the app alive.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else { return 0 }
        return names.filter { !$0.hasSuffix(".tmp") }.count
    }

    // Stay while Claude desktop is open OR a session is active; otherwise quit after a
    // short debounced grace (warmup-session churn must not kill us).
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        if claudeDesktopRunning() || sessionCount() > 0 {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay { NSApp.terminate(nil) }
        } else {
            notNeededSince = now
        }
    }

    // Read the last non-empty line of a (possibly large) file by tailing ~8KB.
    func lastLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 8192
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last { !$0.isEmpty }.map(String.init)
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        self.startedAt = startedAt

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            button.image = dot ? dotIcon(color: color) : restingIcon(color: color)
        }
        applyTitle()
        if button.image == nil { button.image = dot ? dotIcon(color: color) : restingIcon(color: color) }
    }

    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = iconImage(color: activeColor, frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        var text = activeBase
        if showTimer, startedAt > 0 {
            let secs = max(0, Int(Date().timeIntervalSince1970 - startedAt))
            let m = secs / 60, s = secs % 60
            text += "  " + (m > 0 ? "\(m)m \(s)s" : "\(s)s") // Claude Code style: "1m 1s" / "43s"
        }
        // A whisper-quiet "×N" when 2+ sessions are active — restraint over a loud badge.
        let badge = activeCount >= 2 ? "×\(activeCount)" : ""
        if text.isEmpty && badge.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts (white on a dark menu bar, black on a light one); the count uses the
        // same color as the label so it reads as one consistent unit. Monospaced digits keep
        // widths from nudging neighboring menu bar icons.
        let title = NSMutableAttributedString()
        if !text.isEmpty {
            title.append(NSAttributedString(string: " \(text)",
                attributes: [.foregroundColor: NSColor.labelColor, .font: mono]))
        }
        if !badge.isEmpty {
            title.append(NSAttributedString(string: "\(text.isEmpty ? " " : "  ")\(badge)",
                attributes: [.foregroundColor: NSColor.labelColor, .font: mono]))
        }
        button.attributedTitle = title
    }

    // MARK: icon

    static func loadFrames() -> [NSImage] { decodePNGs(claudeSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        if animStyle == .web { return tint(frames, color: color, frame: frame) }
        if animStyle == .crab { return crabIcon(frame: frame) }
        let i = (frame / codeSub) % codeGlyphs.count
        let local = (CGFloat(frame % codeSub) + 0.5) / CGFloat(codeSub) // 0…1 within this glyph
        // Scale envelope per glyph: rise, hold at peak, fall, so each lands before the swap.
        let env: CGFloat
        if local < 0.30 { let u = local / 0.30; env = u * u * (3 - 2 * u) }
        else if local > 0.70 { let u = (1 - local) / 0.30; env = u * u * (3 - 2 * u) }
        else { env = 1 }
        let scale = codeDip + (codePeaks[i] - codeDip) * env
        return codeIcon(color: color, glyph: i, scale: scale)
    }

    // nil color => adaptive template image (system draws it black/white per the menu bar).
    func codeIcon(color: NSColor?, glyph: Int, scale: CGFloat) -> NSImage {
        let s: CGFloat = 18
        guard glyph < codeGlyphMasks.count else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = codeGlyphMasks[glyph]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let dw = s * scale
            let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
            if let c = color {
                c.setFill(); r.fill()
                mask.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Rasterize a single glyph into a centered 60x60 alpha mask filling ~92%.
    static func glyphMask(_ g: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 180), .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: g, attributes: attrs)
        let sz = str.size()
        let big = NSImage(size: sz, flipped: false) { _ in str.draw(at: .zero); return true }
        guard let rep = big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return NSImage(size: NSSize(width: 60, height: 60))
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh, data = rep.bitmapData!
        var minx = w, miny = h, maxx = -1, maxy = -1
        for y in 0..<h { for x in 0..<w where data[(y*w+x)*4+3] > 20 {
            minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        }}
        guard maxx >= 0 else { return NSImage(size: NSSize(width: 60, height: 60)) }
        let bw = CGFloat(maxx - minx + 1), bh = CGFloat(maxy - miny + 1)
        let out: CGFloat = 60, fill = out * 0.92
        let scale = fill / max(bw, bh)
        let dw = bw * scale, dh = bh * scale
        // NSBitmapImageRep origin is top-left; convert the bbox to bottom-left for drawing.
        let srcRect = NSRect(x: CGFloat(minx), y: CGFloat(h - maxy - 1), width: bw, height: bh)
        return NSImage(size: NSSize(width: out, height: out), flipped: false) { _ in
            big.draw(in: NSRect(x: (out - dw)/2, y: (out - dh)/2, width: dw, height: dh),
                     from: srcRect, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    let logoSet: [NSImage] = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    func restingIcon(color: NSColor?) -> NSImage {
        if animStyle == .crab { return crabIcon(frame: 0) }
        return tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0)
    }

    // Full color (isTemplate=false), so the Orange/System color setting does NOT apply here.
    func crabIcon(frame: Int) -> NSImage {
        guard !crabFrames.isEmpty else { return NSImage(size: NSSize(width: 18, height: 18)) }
        let src = crabFrames[frame % crabFrames.count]
        let rep = src.representations.first
        let pw = CGFloat(rep?.pixelsWide ?? Int(src.size.width))
        let ph = CGFloat(rep?.pixelsHigh ?? Int(src.size.height))
        let h: CGFloat = 18, w = (ph > 0 ? h * (pw / ph) : h)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        img.isTemplate = false
        return img
    }

    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha (destinationIn) so frames recolor.
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
