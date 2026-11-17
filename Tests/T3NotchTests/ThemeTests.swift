import AppKit
import Testing
@testable import T3Notch

@Suite struct ThemeTests {
    @Test func snappyLiteralsAndOverlappingCopies() {
        // "abcd" literal, then copy-1 (len 8, offset 4): "abcdabcdabcd".
        let compressed: [UInt8] = [12, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x11, 0x04]
        #expect(LevelDB.snappyDecompress(compressed).map { String(decoding: $0, as: UTF8.self) } == "abcdabcdabcd")
        #expect(LevelDB.snappyDecompress([12, 0x0C, 0x61]) == nil) // truncated
    }

    @Test func logBatchesNewestWins() {
        func batch(_ seq: UInt64, _ key: String, _ value: String) -> [UInt8] {
            var b = (0..<8).map { UInt8(seq >> (8 * $0) & 0xFF) } + [1, 0, 0, 0, 1]
            b += [UInt8(key.utf8.count)] + Array(key.utf8) + [UInt8(value.utf8.count)] + Array(value.utf8)
            return b
        }
        func record(_ payload: [UInt8]) -> [UInt8] {
            [0, 0, 0, 0, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8), 1] + payload
        }
        let log = record(batch(7, "k", "old")) + record(batch(9, "k", "new"))
        var seen: [String: (UInt64, String)] = [:]
        LevelDB.readLog(Data(log)) { key, seq, value in
            let k = String(decoding: key, as: UTF8.self)
            if seq >= seen[k]?.0 ?? 0 { seen[k] = (seq, value.map { String(decoding: $0, as: UTF8.self) } ?? "") }
        }
        #expect(seen["k"]?.1 == "new")
    }

    @Test func localStorageValues() {
        #expect(T3ThemeReader.decodeValue(Data([1]) + Data("ember".utf8)) == "ember")
        #expect(T3ThemeReader.decodeValue(Data([0]) + "iris".data(using: .utf16LittleEndian)!) == "iris")
    }

    @Test func halvesFollowTheVisibleAppearance() {
        let halves = #"{"light":"ember","dark":"ocean"}"#
        #expect(T3ThemeReader.paletteId(theme: "grove", halves: nil, appearance: "light", systemDark: true) == "grove")
        #expect(T3ThemeReader.paletteId(theme: "grove", halves: halves, appearance: "light", systemDark: true) == "ember")
        #expect(T3ThemeReader.paletteId(theme: "grove", halves: halves, appearance: "system", systemDark: true) == "ocean")
        #expect(T3ThemeReader.paletteId(theme: nil, halves: nil, appearance: nil, systemDark: false) == "")
    }

    @Test func classicFillIsTranslucentWhite() {
        #expect(NotchTheme.classic.fill(0.1) == NSColor.white.withAlphaComponent(0.1))
        #expect(NotchTheme.named("ember")?.label == "Ember")
        #expect(NotchTheme.named("dracula") == nil)
    }

    private func hex(_ c: NSColor?) -> String? {
        guard let c = c?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    @Test func oklchToSRGB() {
        #expect(hex(CSSColor.parse("oklch(1 0 0)")?.color) == "FFFFFF")
        #expect(hex(CSSColor.parse("oklch(0 0 0)")?.color) == "000000")
        // CSS reference: oklch(62.8% 0.2577 29.23) is #FF0000 (rounded).
        #expect(hex(CSSColor.parse("oklch(62.8% 0.2577 29.23)")?.color) == "FF0000")
        #expect(hex(CSSColor.parse("#336699")?.color) == "336699") // round trip through OKLCH
        #expect(CSSColor.parse("rgb(1 2 3)") == nil)
    }

    @Test func customThemesUseTheirDarkColors() {
        let json = ##"[{"id":"t3-soft","label":"T3 Soft","appearance":"dark","colors":{"canvas":"oklch(0.191251 0 0)","surfaceRaised":"oklch(0.222129 0 0)","accent":"oklch(0.570912 0.210134 263.99)","accentForeground":"oklch(1 0 0)"},"variants":{"light":{"canvas":"oklch(0.973146 0 0)","accent":"oklch(0.487701 0.217531 264.105)"}}},{"id":"paper","label":"Paper","appearance":"light","colors":{"canvas":"#fafafa","accent":"#0055ff"},"variants":{"dark":{"canvas":"#121212","accent":"#5588ff"}}}]"##
        let soft = NotchTheme.resolve("t3-soft", customThemes: json)
        #expect(soft.label == "T3 Soft")
        #expect(hex(soft.background) == "141414") // the dark canvas, not the light variant
        #expect(hex(soft.surface) == "1B1B1B")
        #expect(hex(soft.onAccent) == "FFFFFF")
        let paper = NotchTheme.resolve("paper", customThemes: json)
        #expect(hex(paper.background) == "121212") // a light theme lends its dark variant
        #expect(hex(paper.accent) == "5588FF")
        #expect(NotchTheme.resolve("missing", customThemes: json) == .classic)
        #expect(NotchTheme.resolve("ember", customThemes: json).label == "Ember")
    }
}

/// Reads this machine's real T3 storage: `T3NOTCH_LIVE=1 swift test --filter liveT3Theme`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["T3NOTCH_LIVE"] != nil))
func liveT3Theme() {
    let (id, stamp, custom) = T3ThemeReader.read(since: nil, systemDark: false)
    let theme = id.map { NotchTheme.resolve($0, customThemes: custom) }
    print("T3 theme:", id ?? "unreadable", "->", theme?.label ?? "-", theme?.background as Any,
          "storage modified:", stamp?.modified as Any)
    #expect(id != nil)
}
