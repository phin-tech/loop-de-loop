import Foundation
import Testing
@testable import LoopCore

@Suite struct ControlRequestTests {
    @Test func parsesCLIArguments() {
        let r = ControlRequest(arguments: ["set-key", "3", "--title", "Hi there", "--bg=ff0000", "--persist"])
        #expect(r?.command == "set-key")
        #expect(r?.positional(0) == "3")
        #expect(r?.args["title"] == "Hi there")
        #expect(r?.args["bg"] == "ff0000")
        #expect(r?.args["persist"] == "true")
    }

    @Test func booleanFlagsDoNotSwallowPositionals() {
        let r = ControlRequest(arguments: ["export", "--all", "full.json"])
        #expect(r?.args["all"] == "true")
        #expect(r?.positional(0) == "full.json")
        let k = ControlRequest(arguments: ["set-key", "--persist", "3", "--title", "x"])
        #expect(k?.positional(0) == "3")
        #expect(k?.args["persist"] == "true")
    }

    @Test func parsesURL() {
        let r = ControlRequest(url: URL(string: "loopdeloop://set-key/3?title=Hi%20there&bg=ff0000")!)
        #expect(r?.command == "set-key")
        #expect(r?.positional(0) == "3")
        #expect(r?.args["title"] == "Hi there")
        #expect(r?.args["bg"] == "ff0000")
        #expect(ControlRequest(url: URL(string: "https://example.com")!) == nil)
    }

    @Test func pageTargets() {
        #expect(PageTarget(argument: "next") == .next)
        #expect(PageTarget(argument: "prev") == .previous)
        #expect(PageTarget(argument: "2") == .index(1))
        #expect(PageTarget(argument: "Media") == .named("Media"))
    }
}

@Suite struct KeyStrokeTests {
    @Test func parsesModifiersAndKey() {
        let k = KeyStroke(parsing: "cmd+shift+4")
        #expect(k?.key == "4")
        #expect(k?.modifiers == [.shift, .command])
        #expect(k?.keyCode == 0x15)
        #expect(KeyStroke(parsing: "ctrl+opt+left")?.keyCode == 0x7b)
        #expect(KeyStroke(parsing: "cmd+nonsense") == nil)
    }
}

@Suite struct ConfigTests {
    @Test func starterConfigRoundTrips() throws {
        let c = Config.starter()
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Config.self, from: data)
        #expect(back == c)
        // Knob dictionaries encode as objects keyed by name, not arrays.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"topLeft\""))
        #expect(json.contains("\"#FFFFFF\""))
    }

    @Test func appearanceOverlayWins() {
        let base = Appearance(title: "A", background: RGB(1, 2, 3), symbol: "x")
        let merged = base.merged(with: Appearance(title: "B"))
        #expect(merged.title == "B")
        #expect(merged.background == RGB(1, 2, 3))
        #expect(merged.symbol == "x")
    }

    @Test func rgbHex() {
        #expect(RGB(hex: "#ff8000") == RGB(255, 128, 0))
        #expect(RGB(hex: "00ff00")?.hex == "#00FF00")
        #expect(RGB(hex: "nope") == nil)
    }
}

@Suite struct ExportTests {
    @MainActor @Test func exportImportRoundTripWithImagesAndRenaming() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ldl-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Engine with one profile whose key uses an image.
        var config = Config.starter()
        config.profiles[0].pages[0].setKey(3, KeyConfig(appearance: Appearance(image: "abc.png")))
        let engine = Engine(config: config, configURL: dir.appendingPathComponent("config.json"),
                            images: ImageStore(directory: dir))
        try engine.images.store(Data([1, 2, 3]), named: "abc.png")

        let file = engine.makeExport(profileIDs: [engine.profileID])
        #expect(file.images["abc.png"] == Data([1, 2, 3]))
        #expect(!file.isFullBackup)

        let decoded = try ExportFile.decode(try file.encoded())
        let names = try engine.importProfiles(from: decoded)
        #expect(names == ["Default (2)"])
        #expect(engine.config.profiles.count == 2)
        #expect(engine.config.profiles[0].id != engine.config.profiles[1].id)
        #expect(engine.config.profiles[1].pages[0].key(3).appearance.image == "abc.png")
    }

    @Test func rejectsForeignJSON() {
        #expect(throws: (any Error).self) { try ExportFile.decode(Data(#"{"hello": 1}"#.utf8)) }
    }
}
