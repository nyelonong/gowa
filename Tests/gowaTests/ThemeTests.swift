import AppKit
import Testing
@testable import gowa

private func glyphs(_ font: NSFont, _ text: String) -> [CGGlyph] {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).flatMap { run -> [CGGlyph] in
        var result = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &result)
        return result
    }
}

@Test("the bundled code font joins => and !== unless code ligatures are off")
func ligatureSetting() throws {
    let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts").standardized
    let regular = fonts.appendingPathComponent("JetBrainsMono-Regular.ttf")
    try #require(FileManager.default.fileExists(atPath: regular.path))
    CTFontManagerRegisterFontsForURL(regular as CFURL, .process, nil)

    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: Theme.ligaturesKey)
    defer { defaults.set(previous, forKey: Theme.ligaturesKey) }

    defaults.set(true, forKey: Theme.ligaturesKey)
    let on = Theme.nsMono(13)
    defaults.set(false, forKey: Theme.ligaturesKey)
    let off = Theme.nsMono(13)

    #expect(on.fontName == "JetBrainsMono-Regular")
    #expect(off.pointSize == 13)
    #expect(glyphs(on, "a => b !== c") != glyphs(off, "a => b !== c"))
    #expect(glyphs(on, "abc") == glyphs(off, "abc"))
}

@Test("appearance choices map to the system, light, and dark appearances")
func appearanceChoices() {
    #expect(Theme.Appearance.system.nsAppearance == nil)
    #expect(Theme.Appearance.light.nsAppearance?.name == .aqua)
    #expect(Theme.Appearance.dark.nsAppearance?.name == .darkAqua)
    #expect(Theme.Appearance(rawValue: "unknown") == nil)
}
