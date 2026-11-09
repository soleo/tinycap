import AppKit
import TinycapCore

/// Where exported recordings go. A folder the user picks is kept as a security-scoped
/// bookmark (user-selected and bookmarks entitlements).
///
/// Until then, the direct build saves to ~/Movies/Tinycap, writable through the
/// assets.movies entitlement it adds in scripts/build-app.sh. The App Store build has no
/// Movies entitlement (App Review guideline 2.4.5(i)), so it has no default folder: the
/// first save asks for one in the standard open panel.
@MainActor
final class SaveLocation {
    static let shared = SaveLocation()

    /// False in the App Store build, which asks for a folder on the first save.
    static var hasDefaultFolder: Bool {
        #if APP_STORE
        return false
        #else
        return true
        #endif
    }

    private var accessedURL: URL?
    private let defaults = UserDefaults.standard

    /// The picked folder, or else the default. In the App Store build, before a folder is
    /// picked, this is only where the open panel starts: Tinycap can't write there.
    var folderURL: URL {
        if let url = resolveBookmark() { return url }
        #if APP_STORE
        return Self.realHomeDirectory
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Tinycap", isDirectory: true)
        #else
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("Tinycap", isDirectory: true)
        #endif
    }

    var isCustom: Bool { defaults.data(forKey: PreferenceKey.saveFolderBookmark) != nil }

    /// True when Tinycap can save without asking: a picked folder that still resolves,
    /// or the direct build's default.
    var isReady: Bool { Self.hasDefaultFolder || resolveBookmark() != nil }

    /// The folder Tinycap can write to now, without asking. Nil in the App Store build
    /// before a folder is picked, or if the picked folder is gone.
    var availableFolder: URL? { isReady ? folderURL : nil }

    /// Returns the folder, creating it if needed. In the App Store build with no usable
    /// folder, asks for one first and throws `FolderError.notChosen` if the user cancels.
    func preparedFolder() throws -> URL {
        if !isReady {
            guard chooseFolder(for: .firstSave) else { throw FolderError.notChosen }
        }
        let url = folderURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum FolderError: LocalizedError {
        /// The user closed the open panel without picking a folder. Callers treat it as a
        /// cancel and show no alert.
        case notChosen
        var errorDescription: String? {
            "No save folder is chosen. Choose one in Settings → General."
        }
    }

    /// The user's home folder, not the sandbox container's.
    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - File names (EX-8, EX-10 to EX-13)

    var pattern: FilenamePattern { FilenamePattern(defaults.string(forKey: PreferenceKey.filenamePattern) ?? "") }

    /// The value `{n}` takes in the next saved file.
    var counter: Int { max(1, defaults.integer(forKey: PreferenceKey.filenameCounter)) }

    /// The pattern's name for a new file, with " 2", " 3"… added if it's taken.
    func suggestedName(for source: CaptureSource, kind: FilenameContext.Kind, pathExtension: String) -> String {
        let base = pattern.baseName(for: source.context(kind, counter: counter))
        // Never asks for a folder: this runs when a window opens, not on a save.
        guard let folder = availableFolder else { return base }
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

    enum ChoosePurpose { case settings, firstSave }

    /// The standard open panel for the save folder. Returns true if a folder was picked
    /// and remembered.
    @discardableResult
    func chooseFolder(for purpose: ChoosePurpose = .settings) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        switch purpose {
        case .settings:
            panel.message = "Choose where Tinycap saves recordings and screenshots."
        case .firstSave:
            panel.message = "Choose a folder for your recordings and screenshots. Tinycap saves there from now on; you can change it in Settings."
        }
        // With no folder yet, start in ~/Movies so the user can make or pick a Tinycap folder there.
        panel.directoryURL = isReady ? folderURL : folderURL.deletingLastPathComponent()
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            stopAccessing()
            defaults.set(data, forKey: PreferenceKey.saveFolderBookmark)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
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
