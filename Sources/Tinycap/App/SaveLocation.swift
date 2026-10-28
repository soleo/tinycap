import AppKit
import TinycapCore

/// Where exported recordings go. Defaults to ~/Movies/Tinycap (writable through the
/// assets.movies entitlement) until the user picks a folder, which is kept as a
/// security-scoped bookmark.
@MainActor
final class SaveLocation {
    static let shared = SaveLocation()

    private var accessedURL: URL?
    private let defaults = UserDefaults.standard

    var folderURL: URL {
        if let url = resolveBookmark() { return url }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("Tinycap", isDirectory: true)
    }

    var isCustom: Bool { defaults.data(forKey: PreferenceKey.saveFolderBookmark) != nil }

    /// Returns the folder, creating it if needed.
    func preparedFolder() throws -> URL {
        let url = folderURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Tinycap saves recordings."
        panel.directoryURL = folderURL
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            stopAccessing()
            defaults.set(data, forKey: PreferenceKey.saveFolderBookmark)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func resetToDefault() {
        stopAccessing()
        defaults.removeObject(forKey: PreferenceKey.saveFolderBookmark)
    }

    func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    private func resolveBookmark() -> URL? {
        if let accessedURL { return accessedURL }
        guard let data = defaults.data(forKey: PreferenceKey.saveFolderBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: PreferenceKey.saveFolderBookmark)
        }
        accessedURL = url
        return url
    }
}

/// Most recent exports, shown under Open Recent.
@MainActor
enum RecentRecordings {
    static var urls: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: PreferenceKey.recentRecordings) ?? []
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var list = RecentList(paths: UserDefaults.standard.stringArray(forKey: PreferenceKey.recentRecordings) ?? [])
        list.add(url.path)
        UserDefaults.standard.set(list.paths, forKey: PreferenceKey.recentRecordings)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.recentRecordings)
    }
}
