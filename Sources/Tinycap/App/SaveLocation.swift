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

    // MARK: - File names (EX-8, EX-10 to EX-13)

    var pattern: FilenamePattern { FilenamePattern(defaults.string(forKey: PreferenceKey.filenamePattern) ?? "") }

    /// The value `{n}` takes in the next saved file.
    var counter: Int { max(1, defaults.integer(forKey: PreferenceKey.filenameCounter)) }

    /// The pattern's name for a new file, with " 2", " 3"… added if it's taken.
    func suggestedName(for source: CaptureSource, kind: FilenameContext.Kind, pathExtension: String) -> String {
        let base = pattern.baseName(for: source.context(kind, counter: counter))
        guard let folder = try? preparedFolder() else { return base }
        return FilenamePattern.uniqueURL(in: folder, baseName: base, pathExtension: pathExtension)
            .deletingPathExtension().lastPathComponent
    }

    /// Where a file with this (already cleaned) name goes. It may exist.
    func destination(named name: String, pathExtension: String) throws -> URL {
        try preparedFolder().appendingPathComponent(name).appendingPathExtension(pathExtension)
    }

    /// The next free " 2", " 3"… variant of `url`, for Keep Both.
    func keepBothURL(for url: URL) -> URL {
        FilenamePattern.uniqueURL(in: url.deletingLastPathComponent(),
                                  baseName: url.deletingPathExtension().lastPathComponent,
                                  pathExtension: url.pathExtension)
    }

    /// Call after a file is saved, so `{n}` moves on.
    func noteSaved() {
        guard pattern.usesCounter else { return }
        defaults.set(counter + 1, forKey: PreferenceKey.filenameCounter)
    }

    /// Renames a saved file in place (EX-13). Refuses to overwrite another file.
    func rename(_ url: URL, to typedName: String) throws -> URL {
        let ext = url.pathExtension
        guard let name = FilenamePattern.clean(typedName, pathExtension: ext) else { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(ext)
        guard target.lastPathComponent != url.lastPathComponent else { return url }
        // A change of case only is the same file on a case-insensitive volume.
        let caseOnly = target.lastPathComponent.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: target.path) {
            throw RenameError.exists(target.lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: target)
        RecentRecordings.add(target)
        return target
    }

    enum RenameError: LocalizedError {
        case exists(String)
        var errorDescription: String? {
            switch self {
            case .exists(let name): return "“\(name)” already exists."
            }
        }
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
