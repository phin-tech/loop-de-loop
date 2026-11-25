import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File locations. Everything lives in ~/Library/Application Support/LoopDeLoop.
public enum Paths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LoopDeLoop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var imagesDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Unix socket the CLI talks to.
    public static var controlSocket: URL { supportDirectory.appendingPathComponent("control.sock") }
}

public enum ConfigStore {
    public static func load(from url: URL = Paths.configFile) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return .starter() }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Config.self, from: data)
        guard config.version <= Config.currentVersion else {
            throw ActionError(description: "config.json is from a newer version (\(config.version))")
        }
        return config
    }

    public static func save(_ config: Config, to url: URL = Paths.configFile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
    }
}

/// Key images, copied into the app's folder so configs don't depend on the original files.
@MainActor
public final class ImageStore {
    public let directory: URL
    private var cache: [String: CGImage] = [:]

    public init(directory: URL = Paths.imagesDirectory) {
        self.directory = directory
    }

    public func image(named name: String) -> CGImage? {
        if let hit = cache[name] { return hit }
        let url = directory.appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache[name] = img
        return img
    }

    /// Copy an image file in; returns the stored name. Same content → same name.
    public func importImage(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = digest + "." + ext
        let dest = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) { try data.write(to: dest) }
        cache[name] = nil
        return name
    }
}
