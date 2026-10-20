import Foundation

/// USB transport: finds `adb`, polls `adb devices` every 2 s and runs
/// `adb -s <serial> reverse tcp:47800 tcp:47800` for every newly authorized device.
@MainActor
final class ADBManager: ObservableObject {
    struct Device: Identifiable, Equatable {
        let serial: String
        let state: String          // "device", "unauthorized", "offline", ...
        var model: String?
        var reversed: Bool
        var id: String { serial }
        var isAuthorized: Bool { state == "device" }
    }

    @Published private(set) var adbPath: String?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var status: String = "Looking for adb…"
    @Published private(set) var downloading = false
    @Published var enabled: Bool = true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "usbEnabled")
            if enabled { start() } else { stop() }
        }
    }

    static let platformToolsURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    private var timer: Timer?
    private var polling = false
    private var reversedSerials: Set<String> = []
    private var pollCount = 0
    private let worker = DispatchQueue(label: "plexi.adb", qos: .utility)

    init() {
        if UserDefaults.standard.object(forKey: "usbEnabled") != nil {
            enabled = UserDefaults.standard.bool(forKey: "usbEnabled")
        }
    }

    static var managedToolsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlexiChore", isDirectory: true)
    }

    static func locateADB() -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            managedToolsDirectory.appendingPathComponent("platform-tools/adb").path,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/usr/local/share/android-commandlinetools/platform-tools/adb",
        ]
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key], !root.isEmpty {
                candidates.insert("\(root)/platform-tools/adb", at: 1)
            }
        }
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") { candidates.append("\(dir)/adb") }
        }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: Lifecycle

    func start() {
        guard enabled, timer == nil else { return }
        adbPath = Self.locateADB()
        if let adb = adbPath {
            status = "Starting adb server…"
            worker.async {
                // Start the daemon with stdio detached so it never holds our pipes open.
                _ = Self.run(adb, ["start-server"], captureOutput: false, timeout: 15)
            }
        } else {
            status = "adb not found — install Android platform-tools or download them below."
        }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        devices = []
        reversedSerials = []
        status = "USB disabled"
    }

    /// Forces `adb reverse` again for every device (e.g. after the server restarted).
    func refresh() {
        reversedSerials.removeAll()
        adbPath = Self.locateADB()
        poll()
    }

    private func poll() {
        guard enabled, !polling else { return }
        if adbPath == nil { adbPath = Self.locateADB() }
        guard let adb = adbPath else { return }
        polling = true
        pollCount += 1
        // Re-assert the reverse mapping every ~30 s in case the adb server was restarted.
        if pollCount % 15 == 0 { reversedSerials.removeAll() }
        let alreadyReversed = reversedSerials
        worker.async { [weak self] in
            let output = Self.run(adb, ["devices", "-l"], captureOutput: true, timeout: 10)
            var parsed = Self.parseDevices(output ?? "")
            var nowReversed = alreadyReversed.intersection(Set(parsed.map(\.serial)))
            for i in parsed.indices where parsed[i].isAuthorized {
                let serial = parsed[i].serial
                if !nowReversed.contains(serial) {
                    let res = Self.run(adb, ["-s", serial, "reverse",
                                             "tcp:\(PlexiProtocol.tcpPort)", "tcp:\(PlexiProtocol.tcpPort)"],
                                       captureOutput: true, timeout: 10)
                    if res != nil { nowReversed.insert(serial) }
                }
                parsed[i].reversed = nowReversed.contains(serial)
            }
            let finalParsed = parsed
            let finalReversed = nowReversed
            let ok = output != nil
            Task { @MainActor in
                guard let self else { return }
                self.polling = false
                self.reversedSerials = finalReversed
                self.devices = finalParsed
                if !ok {
                    self.status = "adb did not respond"
                } else if finalParsed.isEmpty {
                    self.status = "No USB devices. Enable USB debugging on the tablet and plug it in."
                } else if finalParsed.contains(where: { $0.state == "unauthorized" }) {
                    self.status = "Allow USB debugging on the tablet (check its screen)."
                } else {
                    let n = finalParsed.filter(\.reversed).count
                    self.status = "\(n) device\(n == 1 ? "" : "s") ready over USB"
                }
            }
        }
    }

    // MARK: Download

    func downloadPlatformTools() {
        guard !downloading else { return }
        downloading = true
        status = "Downloading Android platform-tools…"
        Task {
            do {
                let (tmp, response) = try await URLSession.shared.download(from: Self.platformToolsURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw URLError(.badServerResponse)
                }
                let dest = Self.managedToolsDirectory
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let zip = dest.appendingPathComponent("platform-tools.zip")
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: tmp, to: zip)
                try? FileManager.default.removeItem(at: dest.appendingPathComponent("platform-tools"))
                let unzip = await Task.detached {
                    Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path], captureOutput: true, timeout: 120)
                }.value
                try? FileManager.default.removeItem(at: zip)
                guard unzip != nil else { throw CocoaError(.fileReadCorruptFile) }
                self.downloading = false
                self.timer?.invalidate()
                self.timer = nil
                self.start()
            } catch {
                self.downloading = false
                self.status = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Helpers

    nonisolated static func parseDevices(_ output: String) -> [Device] {
        var result: [Device] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("List of devices") || s.hasPrefix("*") { continue }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            var model: String?
            for p in parts.dropFirst(2) where p.hasPrefix("model:") {
                model = String(p.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            result.append(Device(serial: parts[0], state: parts[1], model: model, reversed: false))
        }
        return result
    }

    /// Runs a tool synchronously (call from a background queue). Output is redirected to a temp
    /// file instead of a pipe: the adb daemon may inherit the descriptors and would otherwise keep
    /// a pipe open forever. Returns stdout on exit status 0, nil otherwise.
    nonisolated static func run(_ tool: String, _ args: [String], captureOutput: Bool, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        var outURL: URL?
        var outHandle: FileHandle?
        if captureOutput {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("plexi-\(UUID().uuidString).out")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            outURL = url
            outHandle = try? FileHandle(forWritingTo: url)
        }
        process.standardOutput = outHandle ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            try? outHandle?.close()
            if let outURL { try? FileManager.default.removeItem(at: outURL) }
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        try? outHandle?.close()
        defer { if let outURL { try? FileManager.default.removeItem(at: outURL) } }
        guard !process.isRunning, process.terminationStatus == 0 else { return nil }
        guard let outURL else { return "" }
        let data = (try? Data(contentsOf: outURL)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
