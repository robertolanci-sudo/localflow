import AppKit

/// Checks GitHub Releases for a newer LocalFlow. Only the version number is fetched; no data is sent.
final class Updater {
    static let shared = Updater()
    /// "owner/repo" on GitHub whose releases carry the DMG.
    static let repository = "robertolanci-sudo/localflow"

    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks shortly after launch and then once a day, if enabled in settings.
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check(userInitiated: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check(userInitiated: false) }
    }

    func check(userInitiated: Bool) {
        guard userInitiated || SettingsStore.shared.s.checkUpdates,
              let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard status == 200, let json, let tag = json["tag_name"] as? String else {
                    if userInitiated { Updater.alert(L("Impossibile controllare gli aggiornamenti.", "Couldn't check for updates."), info: "GitHub: \(status)") }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Updater.isNewer(latest, than: Updater.currentVersion) else {
                    if userInitiated { Updater.alert(L("LocalFlow è aggiornato", "LocalFlow is up to date"), info: "v\(Updater.currentVersion)") }
                    return
                }
                if !userInitiated, UserDefaults.standard.string(forKey: "skippedVersion") == latest { return }
                let assets = json["assets"] as? [[String: Any]] ?? []
                let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
                let page = json["html_url"] as? String
                Updater.offer(version: latest, notes: json["body"] as? String ?? "", download: URL(string: dmg ?? page ?? ""))
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func offer(version: String, notes: String, download: URL?) {
        let alert = NSAlert()
        alert.messageText = L("È disponibile LocalFlow \(version)", "LocalFlow \(version) is available")
        alert.informativeText = L("Hai la versione \(currentVersion).", "You have version \(currentVersion).")
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        alert.addButton(withTitle: L("Scarica", "Download"))
        alert.addButton(withTitle: L("Più tardi", "Later"))
        alert.addButton(withTitle: L("Salta questa versione", "Skip this version"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: if let download { NSWorkspace.shared.open(download) }
        case .alertThirdButtonReturn: UserDefaults.standard.set(version, forKey: "skippedVersion")
        default: break
        }
    }

    private static func alert(_ title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
