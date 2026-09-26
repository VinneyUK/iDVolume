import AppKit
import CryptoKit
import Foundation

/// A published release on GitHub.
struct AppRelease: Equatable {
    let version: String
    let notes: String
    let page: URL
    let zip: URL
    let checksum: URL?
}

/// Checks GitHub Releases for a newer version, and can download, verify and install it.
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case installing(String)
        case failed(String)
    }

    enum UpdateError: LocalizedError {
        case checksum, missingApp, tool(String)
        var errorDescription: String? {
            switch self {
            case .checksum: return "The download didn't match its checksum, so it wasn't installed."
            case .missingApp: return "The download didn't contain iDVolume.app."
            case .tool(let t): return "\((t as NSString).lastPathComponent) failed while installing."
            }
        }
    }

    static let repo = "VinneyUK/iDVolume"
    private let defaults = UserDefaults.standard
    private enum K {
        static let auto = "updateAutoCheck", install = "updateAutoInstall"
        static let last = "updateLastChecked", skip = "updateSkippedVersion"
    }

    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: K.auto) } }
    @Published var autoInstall: Bool { didSet { defaults.set(autoInstall, forKey: K.install) } }
    @Published private(set) var lastChecked: Date? { didSet { defaults.set(lastChecked, forKey: K.last) } }
    @Published private(set) var status: Status = .idle
    @Published private(set) var skippedVersion: String? { didSet { defaults.set(skippedVersion, forKey: K.skip) } }
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var availableRelease: AppRelease? {
        if case .available(let r) = status { return r }
        return nil
    }

    var isBusy: Bool {
        switch status {
        case .checking, .installing: return true
        default: return false
        }
    }

    init() {
        autoCheck = defaults.object(forKey: K.auto) as? Bool ?? true
        autoInstall = defaults.bool(forKey: K.install)
        lastChecked = defaults.object(forKey: K.last) as? Date
        skippedVersion = defaults.string(forKey: K.skip)
        // Shortly after launch, then hourly: check if a daily check is due.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    // MARK: - Checking

    func checkIfDue() {
        guard autoCheck else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        status = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iDVolume/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handle(data: data, response: response, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        lastChecked = Date()
        if let error {
            status = .failed("Couldn't reach GitHub (\(error.localizedDescription))")
            return
        }
        guard let http = response as? HTTPURLResponse else { status = .failed("No response from GitHub"); return }
        guard http.statusCode == 200, let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            status = .failed(http.statusCode == 404 ? "No releases published yet" : "GitHub returned an error (\(http.statusCode))")
            return
        }
        let version = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ matches: (String) -> Bool) -> URL? {
            for a in assets {
                if let name = a["name"] as? String, matches(name),
                   let s = a["browser_download_url"] as? String, let u = URL(string: s) { return u }
            }
            return nil
        }
        guard let zip = asset({ $0.hasPrefix("iDVolume") && $0.hasSuffix(".zip") }),
              let page = URL(string: json["html_url"] as? String ?? "") else {
            status = .failed("The latest release (\(version)) has no app download attached")
            return
        }
        let release = AppRelease(version: version, notes: json["body"] as? String ?? "", page: page,
                                 zip: zip, checksum: asset({ $0.hasSuffix(".zip.sha256") }))

        guard Self.isVersion(version, newerThan: currentVersion) else { status = .upToDate; return }
        if !userInitiated && skippedVersion == version { status = .upToDate; return }
        status = .available(release)
        if autoInstall && !userInitiated { install(release) }
    }

    /// "1.6.10" > "1.6.2"; missing parts count as 0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func skip(_ release: AppRelease) {
        skippedVersion = release.version
        status = .upToDate
    }

    // MARK: - Installing

    func install(_ release: AppRelease) {
        let appURL = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(release.page)
            status = .failed("iDVolume can't replace itself in this folder, so the release page has been opened instead")
            return
        }
        status = .installing("Downloading \(release.version)…")
        Task {
            do {
                try await self.performInstall(release, replacing: appURL)
            } catch {
                await self.setStatus(.failed(error.localizedDescription))
            }
        }
    }

    @MainActor private func setStatus(_ s: Status) { status = s }

    private func performInstall(_ release: AppRelease, replacing appURL: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("iDVolume-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let (downloaded, _) = try await URLSession.shared.download(from: release.zip)
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: downloaded, to: zip)

        if let sumURL = release.checksum {
            await setStatus(.installing("Verifying…"))
            let (sumData, _) = try await URLSession.shared.data(from: sumURL)
            let expected = String(decoding: sumData, as: UTF8.self)
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map { $0.lowercased() } ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected == actual else { throw UpdateError.checksum }
        }

        await setStatus(.installing("Unpacking…"))
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("iDVolume.app")
        guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.missingApp }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        await setStatus(.installing("Restarting…"))
        // After we quit: swap the apps (restoring the old one if anything fails) and relaunch.
        let pid = ProcessInfo.processInfo.processIdentifier
        let backup = work.appendingPathComponent("previous.app")
        let script = work.appendingPathComponent("swap.sh")
        try """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        if mv "\(appURL.path)" "\(backup.path)" && mv "\(newApp.path)" "\(appURL.path)"; then
          rm -rf "\(backup.path)"
        else
          [ -d "\(backup.path)" ] && mv "\(backup.path)" "\(appURL.path)"
        fi
        open "\(appURL.path)"
        """.write(to: script, atomically: true, encoding: .utf8)
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = [script.path]
        try swap.run()
        await MainActor.run { NSApp.terminate(nil) }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.tool(tool) }
    }
}
