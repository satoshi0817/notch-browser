import AppKit

struct ExternalBrowser: Identifiable, Hashable {
    let id: String
    let name: String
    let appURL: URL
}

enum ExternalBrowserLauncher {
    static func installed(workspace: NSWorkspace = .shared) -> [ExternalBrowser] {
        guard let webURL = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return workspace.urlsForApplications(toOpen: webURL).compactMap { appURL in
            guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? appURL.deletingPathExtension().lastPathComponent
            // Launch Services also lists apps that claim HTTPS for non-browser features.
            guard bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String != "public.app-category.developer-tools",
                  !name.localizedCaseInsensitiveContains("for Testing") else { return nil }
            return ExternalBrowser(id: id, name: name, appURL: appURL)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func open(_ url: URL, bundleID: String?, workspace: NSWorkspace = .shared) {
        guard let bundleID else { workspace.open(url); return }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            let alert = NSAlert()
            alert.messageText = "設定したブラウザが見つかりません"
            alert.informativeText = "設定 › 一般でブラウザを選び直してください。"
            alert.runModal()
            return
        }
        workspace.open([url], withApplicationAt: appURL, configuration: .init()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "ブラウザで開けませんでした"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
