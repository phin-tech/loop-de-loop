import Foundation

/// A portable export: profiles plus the key images they use, in one JSON file.
/// Optionally carries settings, which makes it a full backup.
public struct ExportFile: Codable, Sendable {
    public static let format = "loopdeloop"
    public static let fileExtension = "loopdeloop.json"

    public var format = ExportFile.format
    public var version = Config.currentVersion
    public var exportedAt = Date()
    public var settings: Settings?
    public var defaultProfileID: UUID?
    public var profiles: [Profile]
    /// Image file name → contents (base64 in JSON).
    public var images: [String: Data]

    public var isFullBackup: Bool { settings != nil }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> ExportFile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(ExportFile.self, from: data)
        guard file.format == format else { throw ActionError(description: "not a LoopDeLoop export") }
        guard file.version <= Config.currentVersion else {
            throw ActionError(description: "made by a newer LoopDeLoop (format \(file.version))")
        }
        return file
    }
}

extension Profile {
    /// Image file names used by any key in this profile.
    var imageNames: Set<String> {
        Set(pages.flatMap { $0.keys.values.compactMap(\.appearance.image) })
    }

    /// Same content with fresh IDs, so an import never collides with existing profiles.
    func withNewIDs() -> Profile {
        var p = self
        p.id = UUID()
        p.pages = p.pages.map { var g = $0; g.id = UUID(); return g }
        return p
    }
}

extension Engine {
    /// Build an export of the given profiles (nil = all). `fullBackup` adds settings.
    public func makeExport(profileIDs: [UUID]? = nil, fullBackup: Bool = false) -> ExportFile {
        let profiles = profileIDs.map { ids in config.profiles.filter { ids.contains($0.id) } } ?? config.profiles
        var images: [String: Data] = [:]
        for name in profiles.reduce(into: Set<String>(), { $0.formUnion($1.imageNames) }) {
            if let data = self.images.data(named: name) { images[name] = data }
        }
        return ExportFile(settings: fullBackup ? config.settings : nil,
                          defaultProfileID: fullBackup ? config.defaultProfileID : nil,
                          profiles: profiles, images: images)
    }

    public func export(to url: URL, profileIDs: [UUID]? = nil, fullBackup: Bool = false) throws {
        try makeExport(profileIDs: profileIDs, fullBackup: fullBackup).encoded().write(to: url, options: .atomic)
    }

    /// Add the file's profiles alongside the existing ones. Returns the names they were added under.
    @discardableResult
    public func importProfiles(from file: ExportFile) throws -> [String] {
        try storeImages(file.images)
        var names = Set(config.profiles.map(\.name))
        var added: [Profile] = []
        for p in file.profiles {
            var copy = p.withNewIDs()
            copy.name = uniqueName(p.name, taken: names)
            names.insert(copy.name)
            added.append(copy)
        }
        edit { $0.profiles += added }
        return added.map(\.name)
    }

    /// Replace everything with the file's contents. The current setup is backed up first.
    @discardableResult
    public func restore(from file: ExportFile) throws -> URL {
        guard !file.profiles.isEmpty else { throw ActionError(description: "the file has no profiles") }
        let backup = try backupCurrent()
        try storeImages(file.images)
        var c = Config(profiles: file.profiles)
        if let s = file.settings { c.settings = s }
        if let d = file.defaultProfileID, c.profile(id: d) != nil { c.defaultProfileID = d }
        update(c)
        setProfile(c.defaultProfileID)
        return backup
    }

    /// Write a full backup to Application Support/Backups and return its URL.
    public func backupCurrent() throws -> URL {
        let dir = Paths.supportDirectory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("backup-\(stamp).\(ExportFile.fileExtension)")
        try export(to: url, fullBackup: true)
        return url
    }

    private func storeImages(_ images: [String: Data]) throws {
        for (name, data) in images {
            // Names are content hashes we generated; refuse anything that could escape the folder.
            guard !name.contains("/"), !name.hasPrefix(".") else { continue }
            try self.images.store(data, named: name)
        }
    }

    private func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }
}
