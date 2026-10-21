import AppKit
import Darwin
import Foundation

/// USB transport (parity with Windows `Services/Adb/AdbManager.cs`): finds adb, watches devices
/// (`adb track-devices` for instant (re)appear events + `adb devices -l` polling), and keeps
/// `adb -s <serial> reverse tcp:47800 tcp:47800` applied on every authorized tablet so it can reach this Mac at
/// 127.0.0.1:47800.
///
/// Robustness rules:
/// - Every adb call is `-s <serial>` and has a timeout (SIGTERM, then SIGKILL). All of it runs on a private serial
///   queue; nothing here blocks the main thread.
/// - Never `kill-server`, never `reverse --remove`. If the running adb server has a different protocol version than
///   our adb (any client call would kill and restart it — two tools fighting forever), prefer a matching adb and
///   otherwise stop and expose `.versionMismatch` until the user presses Rescan.
/// - A tablet on a cable *and* wireless debugging is shown once; the reverse goes to the cable (adbd keeps one
///   listener per device port, owned by the transport that applied it last).
/// - Reverse / start-server / track-devices failures retry with exponential backoff.
/// - When we start the adb server ourselves it gets `ADB_MDNS_OPENSCREEN=1` (built-in mDNS backend) so no external
///   `dns-sd` helpers are spawned; child processes are killed on quit.
@MainActor
final class ADBManager: ObservableObject {
    struct Device: Identifiable, Equatable {
        let serial: String
        let state: String          // "device", "unauthorized", "offline", ...
        var model: String?
        var reversed: Bool
        // Additive (defaults keep the original memberwise init valid).
        var transport: Transport = .usbCable
        /// Tablet hardware serial (cable serial, mDNS-embedded serial or `get-serialno`); nil when unknown.
        var hardwareSerial: String? = nil
        var product: String? = nil
        var transportId: String? = nil
        /// Other transports of the same tablet hidden by the dedupe (e.g. its wireless-debugging serial).
        var twinSerials: [String] = []
        /// Consecutive failed `adb reverse` attempts (retried with backoff) and the last adb error.
        var reverseFailures: Int = 0
        var reverseError: String? = nil

        var id: String { serial }
        var isAuthorized: Bool { state == "device" }
        var stateKind: ADBParsing.StateKind { ADBParsing.stateKind(state) }
        var needsAuthorization: Bool { stateKind == .unauthorized }
        var isOffline: Bool { stateKind == .offline }
        var isWirelessTransport: Bool { transport == .wirelessDebugging }
        /// CONFIG `link` this transport would produce.
        var link: SessionPolicy.Link { transport == .usbCable ? .usbCable : .usbWirelessAdb }
    }

    enum Transport: String, Equatable {
        case usbCable = "usb-cable"
        case wirelessDebugging = "usb-wireless-adb"
    }

    /// Machine-readable state for the UI (`status` keeps the human text).
    enum Phase: Equatable {
        case disabled
        case searching
        case notFound
        case downloading
        case startingServer
        case running
        /// `adb devices` failed or timed out (retrying with backoff).
        case unresponsive
        /// A running adb server speaks another protocol version than every adb we found. Talking to it would make
        /// adb kill and restart it (and the other tool would do the same back). `refresh()` overrides.
        case versionMismatch(server: Int, client: Int)
    }

    @Published private(set) var adbPath: String?
    /// One entry per physical tablet (cable preferred; see `Device.twinSerials`).
    @Published private(set) var devices: [Device] = []
    @Published private(set) var status: String = "Looking for adb…"
    @Published private(set) var downloading = false
    @Published var enabled: Bool = true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "usbEnabled")
            if enabled { start() } else { stop() }
        }
    }
    // Additive
    @Published private(set) var phase: Phase = .searching
    /// Every adb transport exactly as `adb devices -l` lists it (no dedupe).
    @Published private(set) var allTransports: [Device] = []
    /// `adb version` release of the adb in use, e.g. "37.0.1-15733141".
    @Published private(set) var adbVersion: String?
    /// Protocol version of the running adb server (41), nil when none is running.
    @Published private(set) var serverVersion: Int?
    /// Last adb error worth showing (stderr line), nil when healthy.
    @Published private(set) var lastFailure: String?
    /// `adb track-devices` is running (instant hot-plug detection).
    @Published private(set) var tracking = false

    static let platformToolsURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
    /// UserDefaults key: absolute path of an adb to use before any other candidate.
    nonisolated static let adbPathOverrideKey = "adbPathOverride"
    /// UserDefaults key (default true): start our adb server with ADB_MDNS_OPENSCREEN=1.
    nonisolated static let mdnsOpenScreenKey = "adbMdnsOpenScreen"

    private let engine = ADBEngine()
    private var terminateObserver: NSObjectProtocol?

    init() {
        if UserDefaults.standard.object(forKey: "usbEnabled") != nil {
            enabled = UserDefaults.standard.bool(forKey: "usbEnabled")
        }
        if !enabled {
            phase = .disabled
            status = "USB disabled"
        }
        engine.onSnapshot = { [weak self] snap in
            Task { @MainActor in self?.apply(snap) }
        }
        // Don't leave `adb track-devices` / in-flight adb clients behind when the app quits.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [engine] _ in
            engine.terminateChildren()
        }
    }

    // MARK: Locating adb

    nonisolated static var managedToolsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlexiChore", isDirectory: true)
    }

    /// Candidate adb paths in preference order (existing executables only, symlinks resolved, deduped):
    /// override → ANDROID_HOME/ANDROID_SDK_ROOT → Android Studio SDK (~/Library/Android/sdk) → Homebrew →
    /// bundled in the app → downloaded by PlexiChore → PATH.
    nonisolated static func adbCandidates() -> [String] {
        let home = NSHomeDirectory()
        let env = ProcessInfo.processInfo.environment
        var list: [String] = []
        if let o = UserDefaults.standard.string(forKey: adbPathOverrideKey), !o.isEmpty { list.append(o) }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key], !root.isEmpty { list.append("\(root)/platform-tools/adb") }
        }
        list += [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/usr/local/share/android-commandlinetools/platform-tools/adb",
            "/opt/homebrew/share/android-sdk/platform-tools/adb",
            "/usr/local/share/android-sdk/platform-tools/adb",
        ]
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "adb") { list.append(aux.path) }
        if let res = Bundle.main.resourceURL { list.append(res.appendingPathComponent("platform-tools/adb").path) }
        list.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/platform-tools/adb").path)
        list.append(managedToolsDirectory.appendingPathComponent("platform-tools/adb").path)
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty { list.append("\(dir)/adb") }
        }
        let fm = FileManager.default
        var seen = Set<String>()
        return list.compactMap { p -> String? in
            guard fm.isExecutableFile(atPath: p) else { return nil }
            let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            return seen.insert(real).inserted ? p : nil
        }
    }

    nonisolated static func locateADB() -> String? { adbCandidates().first }

    // MARK: Lifecycle

    func start() {
        guard enabled else { return }
        if phase == .disabled { phase = .searching; status = "Looking for adb…" }
        engine.start()
    }

    func stop() {
        engine.stop()
        devices = []
        allTransports = []
        tracking = false
        lastFailure = nil
        phase = .disabled
        status = "USB disabled"
    }

    /// Rescan + force `adb reverse` again on every device (e.g. after another tool restarted the adb server).
    /// Also re-locates adb, resets all backoffs and, once, allows talking to a server of another adb version.
    func refresh() {
        guard enabled else { return }
        engine.refresh(relocate: true)
    }

    /// Re-applies the reverse on every device without re-locating adb.
    func reapplyForwarding() {
        guard enabled else { return }
        engine.refresh(relocate: false)
    }

    private func apply(_ s: ADBEngine.Snapshot) {
        guard enabled, !downloading || s.phase == .downloading else { return }
        if adbPath != s.adbPath { adbPath = s.adbPath }
        if devices != s.devices { devices = s.devices }
        if allTransports != s.allTransports { allTransports = s.allTransports }
        if status != s.status { status = s.status }
        if phase != s.phase { phase = s.phase }
        if adbVersion != s.adbVersion { adbVersion = s.adbVersion }
        if serverVersion != s.serverVersion { serverVersion = s.serverVersion }
        if lastFailure != s.lastFailure { lastFailure = s.lastFailure }
        if tracking != s.tracking { tracking = s.tracking }
    }

    // MARK: CONFIG link (AdbManager.ResolveLoopbackLinkAsync)

    /// For a loopback (adb reverse) session: is the reverse served by the cable or by wireless debugging?
    /// Asks adbd (`reverse --list`) on the transports of the tablet whose model matches HELLO `model` (cables first);
    /// falls back to `loopbackLinkHint`. Never blocks the main actor. nil = unknown → omit `link` from CONFIG.
    func resolveLoopbackLink(helloModel: String?, timeout: TimeInterval = 3) async -> SessionPolicy.Link? {
        let hint = loopbackLinkHint(helloModel: helloModel)
        guard phase == .running, let adb = adbPath else { return hint }
        let infos = allTransports.map { SessionPolicy.AdbDeviceInfo(serial: $0.serial, state: $0.state, model: $0.model) }
        let serials = SessionPolicy.adbLinkCandidates(infos, helloModel: helloModel)
        guard !serials.isEmpty else { return hint }
        let env = ADBEngine.adbEnvironment()
        let found: SessionPolicy.Link? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                for s in serials {
                    let r = ADBManager.runFull(adb, ["-s", s, "reverse", "--list"], timeout: timeout, environment: env)
                    if r.ok, let link = ADBParsing.reverseLink(r.output) { cont.resume(returning: link); return }
                }
                cont.resume(returning: nil)
            }
        }
        return found ?? hint
    }

    /// Instant answer from our own bookkeeping: the transport we applied the reverse on for that tablet.
    func loopbackLinkHint(helloModel: String?) -> SessionPolicy.Link? {
        let infos = allTransports.map { SessionPolicy.AdbDeviceInfo(serial: $0.serial, state: $0.state, model: $0.model) }
        for s in SessionPolicy.adbLinkCandidates(infos, helloModel: helloModel) {
            if let d = allTransports.first(where: { $0.serial == s }), d.reversed { return d.link }
        }
        return nil
    }

    // MARK: Download

    func downloadPlatformTools() {
        guard !downloading else { return }
        downloading = true
        phase = .downloading
        status = "Downloading Android platform-tools…"
        engine.setPaused(true)
        Task {
            do {
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 600
                let session = URLSession(configuration: config)
                defer { session.finishTasksAndInvalidate() }
                let (tmp, response) = try await session.download(from: Self.platformToolsURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw URLError(.badServerResponse)
                }
                let dest = Self.managedToolsDirectory
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let zip = dest.appendingPathComponent("platform-tools.zip")
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: tmp, to: zip)
                let staging = dest.appendingPathComponent("platform-tools.staging", isDirectory: true)
                try? FileManager.default.removeItem(at: staging)
                let unzip = await Task.detached {
                    Self.runFull("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path], timeout: 120)
                }.value
                try? FileManager.default.removeItem(at: zip)
                let extracted = staging.appendingPathComponent("platform-tools")
                guard unzip.ok, FileManager.default.isExecutableFile(atPath: extracted.appendingPathComponent("adb").path) else {
                    try? FileManager.default.removeItem(at: staging)
                    throw CocoaError(.fileReadCorruptFile)
                }
                let target = dest.appendingPathComponent("platform-tools")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: extracted, to: target)
                try? FileManager.default.removeItem(at: staging)
                self.downloading = false
                self.phase = .searching
                self.status = "Looking for adb…"
                self.engine.setPaused(false)
                self.engine.refresh(relocate: true)
            } catch {
                self.downloading = false
                self.phase = self.adbPath == nil ? .notFound : .running
                self.status = "Download failed: \(error.localizedDescription)"
                self.lastFailure = self.status
                self.engine.setPaused(false)
            }
        }
    }

    // MARK: Parsing (kept for compatibility; logic lives in ADBParsing)

    nonisolated static func parseDevices(_ output: String) -> [Device] {
        ADBParsing.parseDevices(output).map { ADBEngine.makeDevice($0, reversed: false, resolved: [:]) }
    }

    // MARK: Process runner

    struct RunResult: Sendable {
        var status: Int32 = -1
        var output = ""
        var error = ""
        var timedOut = false
        var launched = false
        var ok: Bool { launched && !timedOut && status == 0 }
        /// First meaningful stderr (else stdout) line, for status text.
        var message: String? { ADBParsing.firstMessageLine(error) ?? ADBParsing.firstMessageLine(output) }
    }

    /// Runs a tool synchronously (call from a background queue). Returns stdout on exit status 0, nil otherwise.
    nonisolated static func run(_ tool: String, _ args: [String], captureOutput: Bool, timeout: TimeInterval) -> String? {
        let r = runFull(tool, args, timeout: timeout, captureOutput: captureOutput)
        return r.ok ? r.output : nil
    }

    /// Runs a tool synchronously with a hard timeout (SIGTERM, then SIGKILL after 2 s). Output goes to temp files
    /// instead of pipes: an adb daemon forked by this client inherits the descriptors and would otherwise keep a
    /// pipe open forever. With `captureOutput == false` all stdio is /dev/null (use for `start-server`).
    nonisolated static func runFull(_ tool: String, _ args: [String], timeout: TimeInterval,
                                    environment: [String: String]? = nil, captureOutput: Bool = true) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let fm = FileManager.default
        func tempFile() -> (URL, FileHandle?) {
            let url = fm.temporaryDirectory.appendingPathComponent("plexi-\(UUID().uuidString).out")
            fm.createFile(atPath: url.path, contents: nil)
            return (url, try? FileHandle(forWritingTo: url))
        }
        var outFile: (URL, FileHandle?)?
        var errFile: (URL, FileHandle?)?
        if captureOutput {
            outFile = tempFile()
            errFile = tempFile()
        }
        process.standardOutput = outFile?.1 ?? FileHandle.nullDevice
        process.standardError = errFile?.1 ?? FileHandle.nullDevice
        defer {
            for f in [outFile, errFile].compactMap({ $0 }) { try? fm.removeItem(at: f.0) }
        }

        var result = RunResult()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            try? outFile?.1?.close()
            try? errFile?.1?.close()
            result.error = error.localizedDescription
            return result
        }
        result.launched = true
        ChildProcesses.shared.add(process)
        defer { ChildProcesses.shared.remove(process) }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            result.timedOut = true
            process.terminate()                       // only this client invocation, never the adb server
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        try? outFile?.1?.close()
        try? errFile?.1?.close()
        if !process.isRunning { result.status = process.terminationStatus }
        func read(_ f: (URL, FileHandle?)?) -> String {
            guard let f, let data = try? Data(contentsOf: f.0) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        result.output = read(outFile)
        result.error = read(errFile)
        return result
    }

    /// Asks the adb server for its protocol version over its socket ("host:version"), without spawning a client
    /// (a client of another version would kill the server). nil = no server listening / no answer.
    nonisolated static func probeServerVersion(port: UInt16 = ADBEngine.serverPort(), timeout: TimeInterval = 1) -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return nil }
        let request = Array("000chost:version".utf8)
        guard send(fd, request, request.count, 0) == request.count else { return nil }
        var reply = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 64)
        while reply.count < 12 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            reply += buf[0..<n]
        }
        return ADBParsing.parseServerVersionReply(String(decoding: reply, as: UTF8.self))
    }
}

/// Children we spawned (adb clients, track-devices), so they can be killed when the app quits.
final class ChildProcesses: @unchecked Sendable {
    static let shared = ChildProcesses()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ p: Process) { lock.lock(); processes[ObjectIdentifier(p)] = p; lock.unlock() }
    func remove(_ p: Process) { lock.lock(); processes[ObjectIdentifier(p)] = nil; lock.unlock() }

    func terminateAll() {
        lock.lock()
        let all = Array(processes.values)
        lock.unlock()
        for p in all where p.isRunning { p.terminate() }
    }
}

/// The adb worker. All mutable state is confined to `queue` (except `ChildProcesses`, which is locked).
final class ADBEngine: @unchecked Sendable {
    struct Snapshot: Equatable {
        var adbPath: String?
        var adbVersion: String?
        var serverVersion: Int?
        var phase: ADBManager.Phase
        var status: String
        var devices: [ADBManager.Device]
        var allTransports: [ADBManager.Device]
        var lastFailure: String?
        var tracking: Bool
    }

    var onSnapshot: (@Sendable (Snapshot) -> Void)?

    // Timings (Windows: 2 s poll, 15 s reverse verification, 10 s per adb call).
    static let pollInterval: TimeInterval = 2
    static let trackedPollInterval: TimeInterval = 5
    static let verifyEvery: TimeInterval = 15
    static let callTimeout: TimeInterval = 10
    static let startServerTimeout: TimeInterval = 20
    static var port: Int { Int(PlexiProtocol.tcpPort) }

    private let queue = DispatchQueue(label: "plexi.adb", qos: .utility)

    // --- queue-confined state ---
    private var running = false
    private var paused = false
    private var generation = 0
    private var periodicToken = 0
    private var pollPending = false

    private var adb: String?
    private var clientVersion: ADBParsing.ClientVersion?
    private var allowVersionMismatch = false
    private var serverVersion: Int?

    private var startServerFailures = 0
    private var nextStartServerAt = Date.distantPast
    private var devicesFailures = 0

    private var reversedAt: [String: Date] = [:]
    private var reverseFailures: [String: (count: Int, next: Date, error: String?)] = [:]
    private var previousReady: Set<String> = []
    private var resolvedSerials: [String: String] = [:]   // wireless transport → hardware serial (get-serialno)
    private var resolveAttempted: Set<String> = []

    private var trackProcess: Process?
    private var trackBuffer: [UInt8] = []
    private var trackStartedAt = Date.distantPast
    private var trackFailures = 0
    private var nextTrackAt = Date.distantPast

    private var lastSnapshot: Snapshot?

    // MARK: Control (any thread)

    func start() {
        queue.async { [self] in
            guard !running else { requestPoll(); return }
            running = true
            generation += 1
            resetBookkeeping()
            pollNow()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            generation += 1
            periodicToken += 1
            stopTracking()
            resetBookkeeping()
            allowVersionMismatch = false
            lastSnapshot = nil
        }
    }

    func refresh(relocate: Bool) {
        queue.async { [self] in
            guard running else { return }
            reversedAt.removeAll()
            reverseFailures.removeAll()
            previousReady.removeAll()
            startServerFailures = 0
            nextStartServerAt = .distantPast
            trackFailures = 0
            nextTrackAt = .distantPast
            if relocate {
                allowVersionMismatch = true
                adb = nil
                clientVersion = nil
                resolvedSerials.removeAll()
                resolveAttempted.removeAll()
                stopTracking()
            }
            requestPoll(after: 0)
        }
    }

    func setPaused(_ p: Bool) {
        queue.async { [self] in
            paused = p
            if p { stopTracking() } else { requestPoll() }
        }
    }

    /// Synchronous, lock-based: safe from `willTerminate` even while the worker is blocked in a call.
    func terminateChildren() {
        ChildProcesses.shared.terminateAll()
    }

    // MARK: Scheduling (queue)

    private func resetBookkeeping() {
        reversedAt.removeAll()
        reverseFailures.removeAll()
        previousReady.removeAll()
        resolvedSerials.removeAll()
        resolveAttempted.removeAll()
        startServerFailures = 0
        nextStartServerAt = .distantPast
        devicesFailures = 0
        trackFailures = 0
        nextTrackAt = .distantPast
    }

    /// Coalesced near-immediate poll (track-devices events, refresh).
    private func requestPoll(after delay: TimeInterval = 0.3) {
        guard running, !pollPending else { return }
        pollPending = true
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.pollPending = false
            self.pollNow()
        }
    }

    /// Single periodic chain: each scheduling invalidates the previous one.
    private func scheduleNext(_ delay: TimeInterval) {
        periodicToken += 1
        let token = periodicToken
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation, token == self.periodicToken else { return }
            self.pollNow()
        }
    }

    // MARK: Poll (queue)

    private func pollNow() {
        guard running else { return }
        if paused { scheduleNext(1); return }
        let now = Date()

        // 1. adb binary
        if adb == nil || !FileManager.default.isExecutableFile(atPath: adb!) {
            stopTracking()
            selectADB()
            guard adb != nil else {
                publish(phase: .notFound, status: "adb not found — install Android platform-tools or download them below.",
                        lines: [], failure: nil)
                scheduleNext(5)
                return
            }
        }

        // 2. Server version guard (never let our client kill someone else's server in a loop).
        serverVersion = ADBManager.probeServerVersion()
        if let server = serverVersion, let client = clientVersion?.protocolVersion, server != client, !allowVersionMismatch {
            if let alt = ADBManager.adbCandidates().first(where: { ADBEngine.version(of: $0)?.protocolVersion == server }) {
                stopTracking()
                adb = alt
                clientVersion = ADBEngine.version(of: alt)
            } else {
                stopTracking()
                publish(phase: .versionMismatch(server: server, client: client),
                        status: "Another app runs adb server v\(server); this adb is v\(client). Close it or press Rescan to take over.",
                        lines: [], failure: nil)
                scheduleNext(5)
                return
            }
        }
        guard let adb else { return }
        let env = Self.adbEnvironment()

        // 3. Start the server ourselves (stdio detached) when none is listening; backoff on failure.
        if serverVersion == nil {
            guard now >= nextStartServerAt else {
                publish(phase: .unresponsive, status: "adb did not respond", lines: [], failure: lastSnapshot?.lastFailure)
                scheduleNext(max(1, nextStartServerAt.timeIntervalSince(now)))
                return
            }
            if lastSnapshot?.phase != .running {
                publish(phase: .startingServer, status: "Starting adb server…", lines: [], failure: nil)
            }
            let r = ADBManager.runFull(adb, ["start-server"], timeout: Self.startServerTimeout,
                                       environment: env, captureOutput: false)
            if r.ok {
                startServerFailures = 0
            } else {
                startServerFailures += 1
                nextStartServerAt = now.addingTimeInterval(ADBParsing.backoff(failures: startServerFailures, base: 2, cap: 60))
            }
        }

        // 4. Devices
        let r = ADBManager.runFull(adb, ["devices", "-l"], timeout: Self.callTimeout, environment: env)
        var failure: String?
        if ADBParsing.reportsServerVersionKill(r.error + r.output) {
            failure = "adb restarted a server started by a different adb version."
        }
        guard r.ok else {
            devicesFailures += 1
            stopTracking()
            if devicesFailures >= 2 { nextStartServerAt = .distantPast }   // let step 3 try start-server again
            let msg = r.timedOut ? "adb devices timed out" : (r.message ?? "adb devices failed (\(r.status))")
            publish(phase: .unresponsive, status: "adb did not respond", lines: [], failure: msg)
            scheduleNext(max(Self.pollInterval, ADBParsing.backoff(failures: devicesFailures, base: 2, cap: 30)))
            return
        }
        devicesFailures = 0
        allowVersionMismatch = false   // the Rescan override is one-shot: never fight another tool in a loop
        let lines = ADBParsing.parseDevices(r.output)

        // 5. Resolve the hardware serial of ready wireless transports once (dedupe with the cable twin).
        let present = Set(lines.map(\.serial))
        resolvedSerials = resolvedSerials.filter { present.contains($0.key) }
        resolveAttempted.formIntersection(present)
        for d in lines where d.isReady && d.isWireless && !resolveAttempted.contains(d.serial) {
            resolveAttempted.insert(d.serial)
            let s = ADBManager.runFull(adb, ["-s", d.serial, "get-serialno"], timeout: 3, environment: env)
            if s.ok, let hw = ADBParsing.parseSerialNo(s.output) { resolvedSerials[d.serial] = hw }
        }

        // 6. Reverse bookkeeping (AdbManager.LoopAsync).
        let ready = Set(lines.filter(\.isReady).map(\.serial))
        reversedAt = reversedAt.filter { ready.contains($0.key) }
        reverseFailures = reverseFailures.filter { ready.contains($0.key) }
        let plan = ADBParsing.reversePlan(lines, resolved: resolvedSerials)
        for s in plan.cableTwinned { reversedAt[s] = nil; reverseFailures[s] = nil }
        // (Re)appeared transports get a fresh reverse — a new cable must take the listener over from its wireless twin.
        for s in ready.subtracting(previousReady) { reversedAt[s] = nil; reverseFailures[s] = nil }
        previousReady = ready

        let wirelessSerials = Set(lines.filter(\.isWireless).map(\.serial))
        var wirelessReversed = false
        for s in plan.targets {   // wireless first, cables last (the last reverse owns the listener)
            guard running else { return }
            if let f = reverseFailures[s], Date() < f.next { continue }
            let wireless = wirelessSerials.contains(s)
            // A wireless transport reversed just now may have taken the listener from a cable: re-check the cables.
            if let at = reversedAt[s], wireless || !wirelessReversed {
                if Date().timeIntervalSince(at) < Self.verifyEvery { continue }
                // Periodic verification: another tool may have restarted the server (rules lost) or removed it, or a
                // wireless twin took the cable's listener.
                let list = ADBManager.runFull(adb, ["-s", s, "reverse", "--list"], timeout: 8, environment: env)
                if list.ok && ADBParsing.reverseHeld(list.output, wireless: wireless, port: Self.port) {
                    reversedAt[s] = Date()
                    continue
                }
            }
            let rr = ADBManager.runFull(adb, ["-s", s, "reverse", "tcp:\(Self.port)", "tcp:\(Self.port)"],
                                        timeout: Self.callTimeout, environment: env)
            if rr.ok {
                if wireless { wirelessReversed = true }
                reversedAt[s] = Date()
                reverseFailures[s] = nil
            } else {
                reversedAt[s] = nil
                let n = (reverseFailures[s]?.count ?? 0) + 1
                let err = rr.timedOut ? "adb reverse timed out" : (rr.message ?? "adb reverse failed")
                reverseFailures[s] = (n, Date().addingTimeInterval(ADBParsing.backoff(failures: n, base: 1, cap: 30)), err)
            }
        }

        // 7. Hot-plug tracking (after the server answered, so the client never forks a daemon on our pipe).
        if trackProcess == nil, Date() >= nextTrackAt { startTracking(adb, env) }

        // 8. Publish
        publish(phase: .running, status: Self.statusText(lines: lines, resolved: resolvedSerials, reversed: reversedAt,
                                                         failures: reverseFailures),
                lines: lines, failure: failure ?? reverseFailures.values.compactMap(\.error).first)
        scheduleNext(trackProcess != nil ? Self.trackedPollInterval : Self.pollInterval)
    }

    private func selectADB() {
        adb = nil
        clientVersion = nil
        // First candidate whose `adb version` runs; prefer one matching a running server's protocol version.
        let server = ADBManager.probeServerVersion()
        var first: (String, ADBParsing.ClientVersion?)?
        for c in ADBManager.adbCandidates() {
            let v = Self.version(of: c)
            guard v != nil else { continue }
            if first == nil { first = (c, v) }
            if server == nil || v?.protocolVersion == server { adb = c; clientVersion = v; return }
        }
        if let first { adb = first.0; clientVersion = first.1 }
    }

    static func version(of adb: String) -> ADBParsing.ClientVersion? {
        // `adb version` never contacts the server.
        let r = ADBManager.runFull(adb, ["version"], timeout: 5)
        return r.ok ? ADBParsing.parseClientVersion(r.output) : nil
    }

    // MARK: track-devices (queue)

    private func startTracking(_ adb: String, _ env: [String: String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["track-devices"]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        let gen = generation
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.trackData(data, gen: gen) }
        }
        p.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.trackEnded(proc, gen: gen) }
        }
        do {
            try p.run()
            trackProcess = p
            trackBuffer.removeAll()
            trackStartedAt = Date()
            ChildProcesses.shared.add(p)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            trackFailures += 1
            nextTrackAt = Date().addingTimeInterval(ADBParsing.backoff(failures: trackFailures, base: 5, cap: 120))
        }
    }

    private func trackData(_ data: Data, gen: Int) {
        guard gen == generation, trackProcess != nil else { return }
        trackBuffer += data
        let (frames, malformed) = ADBParsing.takeTrackFrames(&trackBuffer)
        if !frames.isEmpty || malformed { requestPoll() }
    }

    private func trackEnded(_ p: Process, gen: Int) {
        ChildProcesses.shared.remove(p)
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? (p.standardOutput as? Pipe)?.fileHandleForReading.close()
        guard trackProcess === p else { return }
        trackProcess = nil
        guard gen == generation, running else { return }
        // Short-lived tracker = something is wrong (server died, unsupported): back off; else retry soon.
        trackFailures = Date().timeIntervalSince(trackStartedAt) < 10 ? trackFailures + 1 : 1
        nextTrackAt = Date().addingTimeInterval(ADBParsing.backoff(failures: trackFailures, base: 2, cap: 120))
        requestPoll()
    }

    private func stopTracking() {
        guard let p = trackProcess else { return }
        trackProcess = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }
        ChildProcesses.shared.remove(p)
    }

    // MARK: Snapshot (queue)

    private func publish(phase: ADBManager.Phase, status: String, lines: [ADBParsing.DeviceLine], failure: String?) {
        guard running else { return }
        let all = lines.map { line -> ADBManager.Device in
            var d = Self.makeDevice(line, reversed: reversedAt[line.serial] != nil, resolved: resolvedSerials)
            if let f = reverseFailures[line.serial] { d.reverseFailures = f.count; d.reverseError = f.error }
            return d
        }
        let bySerial = Dictionary(all.map { ($0.serial, $0) }, uniquingKeysWith: { a, _ in a })
        let deduped = ADBParsing.groupByTablet(lines, resolved: resolvedSerials).compactMap { g -> ADBManager.Device? in
            guard var d = bySerial[g.primary.serial] else { return nil }
            d.twinSerials = g.twins.map(\.serial)
            d.reversed = g.members.contains { reversedAt[$0.serial] != nil }
            return d
        }
        let snap = Snapshot(adbPath: adb, adbVersion: clientVersion?.release, serverVersion: serverVersion,
                            phase: phase, status: status, devices: deduped, allTransports: all,
                            lastFailure: failure, tracking: trackProcess != nil)
        guard snap != lastSnapshot else { return }
        lastSnapshot = snap
        onSnapshot?(snap)
    }

    static func makeDevice(_ l: ADBParsing.DeviceLine, reversed: Bool, resolved: [String: String]) -> ADBManager.Device {
        ADBManager.Device(serial: l.serial, state: l.state, model: l.model, reversed: reversed,
                          transport: l.isWireless ? .wirelessDebugging : .usbCable,
                          hardwareSerial: resolved[l.serial] ?? ADBParsing.hardwareSerial(l.serial),
                          product: l.product, transportId: l.transportId)
    }

    static func statusText(lines: [ADBParsing.DeviceLine], resolved: [String: String], reversed: [String: Date],
                           failures: [String: (count: Int, next: Date, error: String?)]) -> String {
        if lines.isEmpty { return "No USB devices. Enable USB debugging on the tablet and plug it in." }
        let groups = ADBParsing.groupByTablet(lines, resolved: resolved)
        let kinds = groups.map { ADBParsing.stateKind($0.primary.state) }
        if kinds.contains(.unauthorized) { return "Allow USB debugging on the tablet (check its screen)." }
        let forwarded = groups.filter { $0.members.contains { reversed[$0.serial] != nil } }.count
        if forwarded > 0 { return "\(forwarded) device\(forwarded == 1 ? "" : "s") ready over USB" }
        if let err = failures.values.compactMap(\.error).first { return "Port forwarding failed (\(err)) — retrying…" }
        if kinds.contains(.ready) { return "Forwarding port 47800…" }
        if kinds.contains(.offline) { return "Tablet offline — unplug and replug the cable, or toggle USB debugging." }
        if kinds.contains(.noPermissions) { return "No permission to use the tablet — reconnect it and accept the prompt." }
        if kinds.contains(.bootMode) { return "Tablet is in \(groups[0].primary.state) mode." }
        return "0 devices ready over USB"
    }

    // MARK: Environment

    /// Environment for adb invocations. Matters when this client has to start the server: the openscreen mDNS
    /// backend is built in, so the server doesn't need external helpers (orphan `dns-sd -B _adb-tls-connect._tcp`).
    static func adbEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let openScreen = UserDefaults.standard.object(forKey: ADBManager.mdnsOpenScreenKey) as? Bool ?? true
        if openScreen, env["ADB_MDNS_OPENSCREEN"] == nil { env["ADB_MDNS_OPENSCREEN"] = "1" }
        return env
    }

    /// adb server port (ANDROID_ADB_SERVER_PORT, default 5037).
    static func serverPort() -> UInt16 {
        ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"].flatMap { UInt16($0) } ?? 5037
    }
}
