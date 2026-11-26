import Foundation

/// The keyboard profile the daemon is following, shared with the DisplayPad
/// thread so the pad shows the keys of the same profile (nil: no keyboard,
/// use the profile selected in the app).
enum ActiveProfile {
    private static let lock = NSLock()
    private static var value: Int?

    static var current: Int? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// DisplayPad half of `everest listen`, on its own thread: the pad and the
/// keyboard come and go independently.
///
/// The pad keeps pictures in RAM only, so every connection (plug-in, Mac
/// wake, profile change) sends all twelve again; a changed key in the config
/// is re-sent within a second.
enum PadDaemon {
    private static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        stderr("\(f.string(from: Date())) pad: \(s)")
    }

    static func start() {
        let t = Thread { run() }
        t.name = "DisplayPad"
        t.start()
    }

    /// How a session ended.
    enum Outcome {
        /// The pad is gone or its handle is stale (unplugged, Mac asleep).
        case gone
        /// It answers but did not take five pictures in a row.
        case notDrawing
    }

    private static func run() {
        var waiting: String?
        var retry: TimeInterval = 2
        // Sessions in a row that ended without a picture taken. The pad can
        // answer commands and still refuse picture data until it is reset
        // (seen after a Mac restart): host mode again first, then a USB
        // reset, then the pad is left as it is, keys still working, with
        // pictures tried now and then and the app saying to replug it.
        var stalls = 0
        func note(_ why: String, _ state: PadState) {
            if waiting != why { log(why); waiting = why }
            state.publish()
        }
        while true {
            autoreleasepool {
                guard DisplayPad.isPresent else {
                    note("not connected — waiting for it", PadState(status: .absent))
                    retry = 2
                    stalls = 0
                    Thread.sleep(forTimeInterval: 2)
                    return
                }
                let pad: DisplayPad
                do {
                    pad = try DisplayPad()
                } catch DisplayPad.PadError.unsupportedFirmware(let v) {
                    // Nothing more is sent to it until it is plugged in again
                    // (possibly after a firmware update).
                    note("firmware \(PadProto.firmwareString(v)) is not the tested one — left alone until it is replugged",
                         PadState(status: .unsupported, firmware: PadProto.firmwareString(v)))
                    while DisplayPad.isPresent { Thread.sleep(forTimeInterval: 2) }
                    return
                } catch {
                    note("left alone — \(error)", PadState(status: .noAnswer))
                    Thread.sleep(forTimeInterval: retry)
                    retry = min(30, retry * 2)
                    return
                }
                waiting = nil
                retry = 2
                let firmware = pad.firmware.map(PadProto.firmwareString)
                let stuck = stalls >= 2
                if stalls == 0 { log("connected (firmware \(firmware ?? "?"))") }
                PadState(status: stuck ? .stalled : .connected, firmware: firmware).publish()
                let outcome = session(pad, stuck: stuck, stalls: &stalls)
                let location = pad.transport.locationID
                pad.close()
                switch outcome {
                case .gone:
                    log("connection lost — reconnecting")
                    stalls = 0
                case .notDrawing:
                    stalls += 1
                    if stalls == 1 {
                        log("no picture taken — setting the pad up again")
                    } else {
                        log("still no picture taken — resetting its USB connection, as a replug would")
                        if let error = DisplayPad.resetUSB(locationID: location) { log("USB reset refused — \(error.localizedDescription)") }
                        // It leaves USB and comes back with a new handle.
                        Thread.sleep(forTimeInterval: 2)
                    }
                }
                PadState(status: .noAnswer).publish()
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// What a key shows, to notice changes: the image path and its date.
    static func signature(_ b: ButtonConfig) -> String {
        guard let p = b.iconPath else { return "" }
        let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        return "\(p)|\(d?.timeIntervalSince1970 ?? 0)"
    }

    /// What a key shows, darkened to the pad brightness (see `PadProto.backlight`).
    static func bgr(for b: ButtonConfig, brightness: Int) -> [UInt8] {
        let raw: [UInt8]
        if let live = b.live, let tile = LiveTiles.image(live, sample: Metrics.latest()),
           let pixels = try? ImageTools.padBGR(image: tile) {
            raw = pixels
        } else {
            raw = b.iconPath.flatMap { try? ImageTools.padBGR(path: $0) } ?? PadProto.solid(r: 0, g: 0, b: 0)
        }
        return PadProto.dim(raw, percent: brightness)
    }

    /// What should be on a key now: its picture, or for a live key the text
    /// of its reading (so it is redrawn only when that changes).
    static func wanted(_ b: ButtonConfig, sample: () -> MetricsSample) -> String {
        if let live = b.live { return LiveTiles.signature(live, sample: sample()) }
        return signature(b)
    }

    private static func configDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Config.file.path))?[.modificationDate] as? Date
    }

    /// `stuck`: the pad did not take pictures even after a USB reset. The
    /// session then keeps serving its keys and only tries a picture now and
    /// then; the first one taken puts `stalls` back to 0.
    private static func session(_ pad: DisplayPad, stuck: Bool, stalls: inout Int) -> Outcome {
        var cfg = Config.load()
        func profile() -> Int { ActiveProfile.current ?? cfg.selectedProfile }

        var shownProfile = 0
        var shown = [String](repeating: "-", count: PadProto.keyCount)
        var wanted = [String](repeating: "", count: PadProto.keyCount)
        var brightness: Int?
        var configStamp = configDate()
        var lastCheck = Date.distantPast
        var lastPing = Date()
        var missedPings = 0
        var lastTick = Date()
        var failures = 0
        var retryAt = Date.distantPast
        var lastError: String?
        var held = Set<Int>()
        var lastFired = [Date](repeating: .distantPast, count: PadProto.keyCount)
        // Night mode: backlight 0 (the screen switches off) and black keys
        // that are not redrawn until morning.
        var night = NightMode.active
        var level: Int { night ? 0 : cfg.padBrightness }

        while true {
            let stop: Outcome? = autoreleasepool {
                let now = Date()
                // A long gap means the Mac slept: the pad may have been reset.
                if now.timeIntervalSince(lastTick) > 10 {
                    log("woke up — setting the pad up again")
                    guard (try? pad.enable(timeout: 8)) != nil else { return .gone }
                    shown = shown.map { _ in "-" }
                    brightness = nil
                }
                lastTick = now

                // A profile key with no keyboard session to take it: the
                // profile is the app's selection, saved in the config.
                if ActiveProfile.current == nil, let request = ProfileRequest.take(),
                   let target = ProfileRequest.resolve(request, current: cfg.selectedProfile, config: cfg),
                   target != cfg.selectedProfile {
                    cfg.selectedProfile = target
                    cfg.save()
                    log("profile \(target) (profile key, no keyboard)")
                    lastCheck = .distantPast
                }

                // Config and picture files, once a second.
                if now.timeIntervalSince(lastCheck) >= 1 {
                    lastCheck = now
                    let stamp = configDate()
                    if stamp != configStamp { configStamp = stamp; cfg = Config.load() }
                    let p = profile()
                    if p != shownProfile { shown = shown.map { _ in "-" }; shownProfile = p }
                    let keys = cfg.padButtons(for: p)
                    var sample: MetricsSample?
                    night = NightMode.active
                    wanted = night ? keys.map { _ in "night" } : keys.map { b in PadDaemon.wanted(b) {
                        if sample == nil { sample = Metrics.latest(maxAge: 0.9) }
                        return sample!
                    } }
                }

                if !PadBusy.active {
                    if now >= retryAt {
                        do {
                            if brightness != level {
                                try pad.setBrightness(PadProto.backlight(for: level))
                                brightness = level
                                shown = shown.map { _ in "-" }   // redraw at the new level
                            }
                            let keys = cfg.padButtons(for: shownProfile)
                            let changed = (0..<PadProto.keyCount).filter { wanted[$0] != shown[$0] }
                            // Said for a whole redraw (connection, profile,
                            // brightness), not for live keys changing.
                            let all = shown.allSatisfy { $0 == "-" }
                            var taken = false
                            defer {
                                if taken {
                                    if stalls > 0 {
                                        if stuck { log("pictures taken again") }
                                        stalls = 0
                                        PadState(status: .connected, firmware: pad.firmware.map(PadProto.firmwareString)).publish()
                                    }
                                }
                            }
                            if !changed.isEmpty {
                                try pad.setKeyImages(changed.map { ($0, bgr(for: keys[$0], brightness: level)) }) { k in
                                    shown[k] = wanted[k]
                                    taken = true
                                }
                                if all { log("profile \(shownProfile): \(changed.count) keys drawn") }
                            }
                            failures = 0
                            lastError = nil
                        } catch let e as DisplayPad.PadError {
                            if failed("\(e)") { return .notDrawing }
                        } catch let e as PadPixelPipe.PipeError {
                            if failed("\(e)") { return .notDrawing }
                        } catch {
                            return .gone   // write failed: unplugged
                        }
                    }

                    // Keep-alive on its own schedule: three unanswered queries
                    // in a row mean the handle is stale.
                    if now.timeIntervalSince(lastPing) >= 3 {
                        lastPing = now
                        let answer: Int?
                        do { answer = try pad.brightness() } catch { return .gone }   // write failed
                        missedPings = answer == nil ? missedPings + 1 : 0
                        if missedPings >= 3 { return .gone }
                    }
                }

                // Key presses fire on the way down, like D1–D4.
                while let pressed = pad.nextEvent(timeout: 0.05) {
                    let keys = cfg.padButtons(for: profile())
                    for k in pressed.subtracting(held).sorted() where Date().timeIntervalSince(lastFired[k]) >= 0.25 {
                        lastFired[k] = Date()
                        let b = keys[k]
                        log("P\(k + 1) pressed — \(b.name ?? b.action.type.rawValue): \(b.action.value)")
                        ActionRunner.run(b.action)
                    }
                    held = pressed
                }
                return nil
            }
            if let stop { return stop }
            Thread.sleep(forTimeInterval: 0.05)
        }

        /// A picture did not go through: wait longer each time, say so once,
        /// and end the session after five failures in a row (`run` sets the
        /// pad up again, then resets it). A stuck pad's session goes on, for
        /// its keys, and tries a picture once a minute.
        func failed(_ message: String) -> Bool {
            failures += 1
            if message != lastError {
                log(stuck ? "\(message) — unplug the DisplayPad and plug it in again; trying once a minute"
                          : "\(message) — retrying")
                lastError = message
            }
            retryAt = Date().addingTimeInterval(stuck ? 60 : min(30, 0.5 * pow(2, Double(failures))))
            return !stuck && failures >= 5
        }
    }
}

/// What the daemon knows about the pad, for the app's status line
/// (`.pad-state` in the config directory).
struct PadState: Codable, Equatable {
    /// `stalled`: it answers and its keys work, but it takes no picture,
    /// even after a USB reset; a replug clears it.
    enum Status: String, Codable { case absent, noAnswer, unsupported, connected, stalled }
    var status: Status
    var firmware: String?

    static var url: URL { Config.directory.appendingPathComponent(".pad-state") }

    func publish() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? data.write(to: PadState.url, options: .atomic)
    }

    static func read() -> PadState? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PadState.self, from: $0) }
    }
}

/// Marker files: another program (the app while the daemon is off, a CLI
/// command, the self-test) is talking to the DisplayPad; the daemon stays off
/// the command channel meanwhile. One file per process, so one finishing does
/// not clear another's; a crashed process's marker is ignored.
enum PadBusy {
    private static let prefix = ".pad-busy."
    private static var url: URL { Config.directory.appendingPathComponent(prefix + "\(getpid())") }

    static func set() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    static var active: Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Config.directory.path) else { return false }
        return names.contains { name in
            guard name.hasPrefix(prefix), let pid = Int32(name.dropFirst(prefix.count)), pid != getpid(),
                  kill(pid, 0) == 0 || errno == EPERM else { return false }
            let path = Config.directory.appendingPathComponent(name).path
            let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return d.map { Date().timeIntervalSince($0) < 120 } ?? false
        }
    }
}

/// `everest pad …`
enum PadCommand {
    static func run(_ args: [String]) {
        guard let sub = args.first else { usage(); exit(1) }
        let rest = Array(args.dropFirst())
        // Check the arguments before taking the pad.
        switch sub {
        case "info", "keys", "reset": break
        case "image", "color": guard rest.count >= 2 else { usage(); exit(1) }; _ = key(rest[0])
        case "clear": if let k = rest.first { _ = key(k) }
        case "brightness":
            guard let v = rest.first.flatMap(Int.init), (0...100).contains(v) else { fail("usage: everest pad brightness <0-100>") }
        default: usage(); exit(1)
        }
        let color = sub == "color" ? parseColor(rest[1]) : nil

        if sub == "reset" {
            // The reset takes the whole device: no session of ours is open.
            guard DisplayPad.isPresent else { fail("Error: \(DisplayPad.PadError.notFound)") }
            PadBusy.set()
            defer { PadBusy.clear() }
            if let error = DisplayPad.resetUSB(locationID: nil) { PadBusy.clear(); fail("Error: USB reset refused (\(error.localizedDescription))") }
            let back = Date().addingTimeInterval(10)
            Thread.sleep(forTimeInterval: 1)
            while !DisplayPad.isPresent && Date() < back { Thread.sleep(forTimeInterval: 0.3) }
            print(DisplayPad.isPresent ? "DisplayPad reset: it is back on USB (`everest listen` redraws its keys)"
                                       : "DisplayPad reset, but it has not come back yet: unplug it and plug it in again")
            return
        }

        PadBusy.set()
        func bail(_ message: String) -> Never { PadBusy.clear(); fail(message) }
        let pad: DisplayPad
        do { pad = try DisplayPad(allowUnsupported: sub == "info") } catch { bail("Error: \(error)") }
        defer { pad.close(); PadBusy.clear() }
        do {
            switch sub {
            case "info":
                print("DisplayPad 3282:0009")
                print("  firmware   \(pad.firmware.map(PadProto.firmwareString) ?? "unknown")"
                      + (PadProto.isSupported(pad.firmware) ? " (tested)" : " (NOT tested: read-only)"))
                if PadProto.isSupported(pad.firmware), let b = try pad.brightness() { print("  backlight  \(b) %") }
            case "image":
                try pad.setKeyImage(key(rest[0]), bgr: ImageTools.padBGR(path: rest[1]))
                print("Key \(rest[0]) updated (until the pad is unplugged)")
            case "color":
                let (r, g, b) = color!
                try pad.setKeyImage(key(rest[0]), bgr: PadProto.solid(r: r, g: g, b: b))
                print("Key \(rest[0]) set to #\(rest[1])")
            case "clear":
                let keys = rest.first.map { [key($0)] } ?? Array(0..<PadProto.keyCount)
                try pad.setKeyImages(keys.map { ($0, PadProto.solid(r: 0, g: 0, b: 0)) })
                print("Cleared \(keys.count) key(s)")
            case "brightness":
                // Like the other pad commands, this lasts until the next
                // redraw; the saved level is the app's (config.json).
                let v = Int(rest[0])!
                let cfg = Config.load()
                let keys = cfg.padButtons(for: cfg.selectedProfile)
                try pad.setBrightness(PadProto.backlight(for: v))
                try pad.setKeyImages((0..<PadProto.keyCount).map { ($0, PadDaemon.bgr(for: keys[$0], brightness: v)) })
                print("Keys redrawn at \(PadProto.brightnessLevel(v)) % (until the next redraw; set it in the app to keep it)")
            default:
                let seconds = rest.first.flatMap(Double.init) ?? 15
                print("Press DisplayPad keys for \(Int(seconds)) s…")
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if let k = pad.nextEvent(timeout: 0.2) {
                        print(k.isEmpty ? "  released" : "  pressed " + k.sorted().map { "P\($0 + 1)" }.joined(separator: " "))
                    }
                }
            }
        } catch {
            pad.close()
            bail("Error: \(error)")
        }
    }

    private static func key(_ s: String) -> Int {
        guard let i = Int(s), (1...PadProto.keyCount).contains(i) else { fail("key must be 1-12 (top row 1-6, bottom row 7-12)") }
        return i - 1
    }

    static func usage() {
        print("""
        usage: everest pad <command>
          info                      firmware and backlight
          image <1-12> <file>       picture on a key (until the pad is unplugged)
          color <1-12> <RRGGBB>     solid colour on a key
          clear [1-12]              blank one key or all of them
          brightness <0-100>        redraw the keys at that brightness (not saved)
          keys [seconds]            print key presses
          reset                     reset its USB port, as a replug would (keys redrawn by `everest listen`)
        Keys and pictures that stay belong in the app (DisplayPad page) or
        config.json (`pad` in each profile); `everest listen` applies them.
        """)
    }
}
