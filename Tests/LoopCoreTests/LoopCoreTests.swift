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
