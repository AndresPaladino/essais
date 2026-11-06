import AppKit

extension NSAttributedString.Key {
    /// The day (YYYY-MM-DD) a piece of text was written on. Typed text inherits it from its neighbour.
    static let day = NSAttributedString.Key("EssaisDay")
    /// Marks the date line that opens a day. It is not part of the file and can't be edited.
    static let dateLine = NSAttributedString.Key("EssaisDateLine")
}

enum Paper {
    static let sheet = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.122, alpha: 1) : NSColor(srgbRed: 0.996, green: 0.996, blue: 0.992, alpha: 1) }
    /// Dates and #tags: quiet, but readable (≥ 4.5:1 on the paper); darker with Increase Contrast.
    static let secondaryInk = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .accessibilityHighContrastAqua: NSColor(white: 0.22, alpha: 1)
        case .accessibilityHighContrastDarkAqua: NSColor(white: 0.85, alpha: 1)
        case .darkAqua: NSColor(white: 0.66, alpha: 1)
        default: NSColor(white: 0.40, alpha: 1)
        }
    }
    /// Markdown marks (`#`, `*`): present but in the background (~3:1).
    static let markInk = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .accessibilityHighContrastAqua: NSColor(white: 0.35, alpha: 1)
        case .accessibilityHighContrastDarkAqua: NSColor(white: 0.72, alpha: 1)
        case .darkAqua: NSColor(white: 0.50, alpha: 1)
        default: NSColor(white: 0.58, alpha: 1)
        }
    }
    static let desk = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.094, green: 0.09, blue: 0.086, alpha: 1) : NSColor(srgbRed: 0.91, green: 0.898, blue: 0.875, alpha: 1) }
    /// Height ÷ width of a page: A5.
    static let ratio: CGFloat = 1.414
}

enum Fonts: String, CaseIterable {
    case newYork, charter, iowan, system

    var title: String {
        switch self {
        case .newYork: "New York"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        case .system: String(localized: "System")
        }
    }

    /// Fonts are asked for once per paragraph: years of writing asked for thousands of the same ones.
    nonisolated(unsafe) private static var cache: [Fonts: [CGFloat: NSFont]] = [:]

    func font(_ size: CGFloat) -> NSFont {
        if let font = Self.cache[self]?[size] { return font }
        let system = NSFont.systemFont(ofSize: size)
        let font: NSFont
        switch self {
        case .newYork: font = system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .charter: font = NSFont(name: "Charter-Roman", size: size) ?? system
        case .iowan: font = NSFont(name: "IowanOldStyle-Roman", size: size) ?? system
        case .system: font = system
        }
        Self.cache[self, default: [:]][size] = font
        return font
    }

    /// The same font in bold, italic or both.
    nonisolated(unsafe) private static var traitCache: [NSFont: [UInt: NSFont]] = [:]

    static func font(_ font: NSFont, with traits: NSFontTraitMask) -> NSFont {
        if let found = traitCache[font]?[traits.rawValue] { return found }
        var result = font
        for trait in [NSFontTraitMask.boldFontMask, .italicFontMask] where traits.contains(trait) {
            result = NSFontManager.shared.convert(result, toHaveTrait: trait)
        }
        traitCache[font, default: [:]][traits.rawValue] = result
        return result
    }
}

/// The only two choices the notebook offers, both for legibility.
enum Reading {
    static let sizes: ClosedRange<CGFloat> = 13...30
    static var font: Fonts {
        get { Fonts(rawValue: UserDefaults.standard.string(forKey: "font") ?? "") ?? .newYork }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "font") }
    }
    static var size: CGFloat {
        get { let s = UserDefaults.standard.double(forKey: "size"); return s == 0 ? 17 : CGFloat(s) }
        set { UserDefaults.standard.set(Double(min(max(newValue, sizes.lowerBound), sizes.upperBound)), forKey: "size") }
    }

    static var body: NSFont { font.font(size) }

    /// What VoiceOver says after the size changes.
    static var sizeAnnouncement: String { String(localized: "\(Int(size))-point text") }

    /// How a line of writing sits on the page. The day is the notebook's unit, so it gets the most
    /// air; a title has more above than below; list items stay together.
    enum Line { case body, title, item }

    nonisolated(unsafe) private static var paragraphs: [CGFloat: [Line: NSParagraphStyle]] = [:]

    static func paragraph(_ line: Line = .body) -> NSParagraphStyle {
        let size = size
        if let found = paragraphs[size]?[line] { return found }
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.22
        switch line {
        case .body:
            p.paragraphSpacing = (size * 0.55).rounded()
        case .title:
            p.paragraphSpacingBefore = (size * 0.8).rounded()
            p.paragraphSpacing = (size * 0.3).rounded()
        case .item:
            p.paragraphSpacing = (size * 0.15).rounded()
        }
        paragraphs[size, default: [:]][line] = p
        return p
    }

    static func bodyAttributes(day: String) -> [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph(), .day: day]
    }

    static func dateLine(_ date: Date, day: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = (size * 1.8).rounded()
        p.paragraphSpacing = (size * 0.5).rounded()
        // The year appears when it isn't this one: after a few years, "9 January" alone says little.
        let thisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let words = (thisYear ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
                              : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).uppercased()
        return NSAttributedString(string: words + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: max(10.5, size * 0.62), weight: .semibold),
            // A system color, so Increase Contrast darkens it like the rest of macOS.
            .foregroundColor: Paper.secondaryInk,
            .kern: 0.6, .paragraphStyle: p, .day: day, .dateLine: true,
        ])
    }
}

/// Markdown in place, marks kept visible and quiet. Only adds attributes, so the day each
/// character belongs to survives restyling.
enum Markdown {
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,3})[ \t]+"#)
    private static let quote = try! NSRegularExpression(pattern: #"^>[ \t]?"#)
    private static let item = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+"#)
    /// `*` may fall inside a word, but not after a number (5*2 y 3*4 is arithmetic).
    private static let stars = try! NSRegularExpression(pattern: #"(?<![\p{N}*\\])(\*{1,3})(?=[^\s*])(.+?)(?<=[^\s*])\1(?!\*)"#)
    /// `_` only at the edge of a word: snake_case_name and URLs are not emphasis.
    private static let underscores = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}\p{M}_\\])(_{1,3})(?=[^\s_])(.+?)(?<=[^\s_])\1(?![\p{L}\p{N}\p{M}_])"#)
    /// A #tag: has a letter, doesn't follow a word or a URL's slash, and doesn't end in a hyphen.
    /// Accents count whether composed or not. Colors like #ff0000 aren't tags. Capture 1: the name.
    static let tag = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}\p{M}_#&/])#(?=[\p{N}_-]*\p{L})(?!(?=[0-9a-fA-F]*[0-9])(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![\p{L}\p{N}\p{M}_-]))([\p{L}\p{N}\p{M}_-]*[\p{L}\p{N}\p{M}_])"#)

    static func style(_ text: NSMutableAttributedString, in range: NSRange) {
        let ns = text.string as NSString
        var location = range.location
        repeat {
            let paragraph = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
            if paragraph.length > 0, text.attribute(.dateLine, at: paragraph.location, effectiveRange: nil) == nil {
                styleParagraph(text, paragraph)
            }
            location = NSMaxRange(paragraph)
        } while location < NSMaxRange(range) && location < ns.length
    }

    private static func styleParagraph(_ text: NSMutableAttributedString, _ range: NSRange) {
        let line = (text.string as NSString).substring(with: range)
        let whole = NSRange(location: 0, length: (line as NSString).length)
        let quiet = Paper.markInk
        // An empty line only separates paragraphs; the paragraph spacing already does that.
        if line.trimmingCharacters(in: .newlines).isEmpty {
            text.addAttributes([.font: Reading.font.font(Reading.size * 0.35), .paragraphStyle: NSParagraphStyle.default], range: range)
            return
        }
        var font = Reading.body
        var marks: [NSRange] = []
        var kind = Reading.Line.body
        if let m = heading.firstMatch(in: line, range: whole) {
            font = Fonts.font(Reading.font.font(Reading.size * [1, 1.3, 1.15, 1.08][m.range(at: 1).length]), with: .boldFontMask)
            marks.append(m.range)
            kind = .title
        } else if let m = quote.firstMatch(in: line, range: whole) {
            font = Fonts.font(font, with: .italicFontMask)
            marks.append(m.range)
        } else if let m = item.firstMatch(in: line, range: whole) {
            marks.append(m.range)
            kind = .item
        }
        text.addAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: Reading.paragraph(kind)], range: range)
        let at = { (r: NSRange) in NSRange(location: range.location + r.location, length: r.length) }
        for rule in [stars, underscores] {
            for m in rule.matches(in: line, range: whole) {
                let markLength = m.range(at: 1).length
                let traits: NSFontTraitMask = markLength == 1 ? .italicFontMask : markLength == 2 ? .boldFontMask : [.boldFontMask, .italicFontMask]
                text.addAttribute(.font, value: Fonts.font(font, with: traits), range: at(m.range(at: 2)))
                marks += [NSRange(location: m.range.location, length: markLength), NSRange(location: NSMaxRange(m.range) - markLength, length: markLength)]
            }
        }
        for r in marks { text.addAttribute(.foregroundColor, value: quiet, range: at(r)) }
        for m in tag.matches(in: line, range: whole) {
            text.addAttribute(.foregroundColor, value: Paper.secondaryInk, range: at(m.range))
        }
    }
}
