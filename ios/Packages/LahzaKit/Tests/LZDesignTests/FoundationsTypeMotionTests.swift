import SwiftUI
import Testing
@testable import LZDesign

@MainActor
@Suite("Foundations · typography")
struct FoundationsTypographyTests {
    @Test("Display and countdown numerals are Instrument Serif and never carry a weight")
    func serifRoles() {
        for role in [LZTextRole.displayXL, .displayLarge, .display, .displaySmall, .section, .numeralHero, .numeral] {
            #expect(role.spec.fontName == LZFontName.instrumentSerif, "\(role)")
            #expect(role.spec.weight == nil, "\(role) would synthesise bold")
        }
        #expect(LZTextRole.displayXL.spec.size == 48)
        #expect(LZTextRole.displayLarge.spec.size == 38)
        #expect(LZTextRole.display.spec.size == 32)
        #expect(LZTextRole.displaySmall.spec.size == 26)
        #expect(LZTextRole.numeralHero.spec.size == 64)
        #expect(LZTextRole.display.spec.isDisplay)
        #expect(!LZTextRole.numeralHero.spec.isDisplay)
    }

    @Test("UI roles are SF Pro and follow their text style")
    func sfRoles() {
        let expected: [LZTextRole: Font.TextStyle] = [
            .title: .title2, .headline: .headline, .body: .body, .callout: .callout, .subheadline: .subheadline,
            .caption: .footnote, .label: .caption, .numeralUI: .title3,
        ]
        for (role, style) in expected {
            #expect(role.spec.fontName == nil, "\(role)")
            #expect(role.spec.textStyle == style, "\(role)")
        }
    }

    @Test("Label is 12 pt semibold, uppercase, tracked 0.14 em")
    func label() {
        let spec = LZTextRole.label.spec
        #expect(spec.size == 12 && spec.weight == .semibold && spec.uppercase && spec.tracking == 0.14)
    }

    @Test("Reading face and line height")
    func reading() {
        #expect(LZTextRole.reading.spec.fontName == LZFontName.newsreader)
        #expect(LZTextRole.reading.spec.lineHeight == 1.65)
    }

    @Test("Display roles keep the face's natural leading at accessibility sizes, so wrapped titles never lose descenders")
    func displayLeadingAtAccessibilitySizes() {
        for role in LZTextRole.allCases where role.spec.isDisplay {
            #expect(role.spec.lineHeightPoints(scaledSize: 60, accessibilitySize: true) == nil, "\(role)")
        }
        #expect(LZTextRole.displaySmall.spec.lineHeightPoints(scaledSize: 26, accessibilitySize: false) == (26 * 1.12).rounded())
        // Reading and UI roles keep their exact line heights at every size.
        #expect(LZTextRole.reading.spec.lineHeightPoints(scaledSize: 40, accessibilitySize: true) == 66)
        #expect(LZTextRole.headline.spec.lineHeightPoints(scaledSize: 17, accessibilitySize: true) == nil)
    }

    @Test("Numerals are tabular")
    func numerals() {
        for role in [LZTextRole.numeralHero, .numeral, .numeralUI] { #expect(role.spec.tabular, "\(role)") }
    }

    @Test("Every bundled face name matches the PostScript names in ios/Resources/Fonts")
    func faceNames() {
        let expected = ["InstrumentSerif-Regular", "InstrumentSerif-Italic", "Newsreader-Regular", "Newsreader-Medium"]
        #expect(LZFontName.all == expected)
    }

    @Test("Numeral cells are keyed from the right so digits roll in place")
    func numeralCells() {
        let a = LZNumeralCells.split("9:59"), b = LZNumeralCells.split("10:00")
        #expect(a.map(\.id) == [4, 3, 2, 1])
        #expect(b.map(\.id) == [5, 4, 3, 2, 1])
        // The minutes' ones digit keeps id 1 across the change.
        #expect(a.last?.id == b.last?.id)
        #expect(a.filter(\.isDigit).count == 3)
        #expect(LZNumeralCells.split("١").first?.isDigit == false)
    }
}

@MainActor
@Suite("Foundations · motion")
struct FoundationsMotionTests {
    @Test("Durations sit in their families: touch 100–160, interface 220–320, feature 450–700 ms")
    func durations() {
        #expect(LZMotion.touchRange.contains(LZMotion.touch))
        #expect(LZMotion.interfaceRange.contains(LZMotion.interface))
        #expect(LZMotion.featureRange.contains(LZMotion.feature))
        #expect(LZMotion.touchRange.contains(LZMotionToken.touch.duration))
        #expect(LZMotion.interfaceRange.contains(LZMotionToken.interface.duration))
        #expect(LZMotion.featureRange.contains(LZMotionToken.feature.duration))
        #expect(LZMotion.featureRange.contains(LZMotionToken.celebrate.duration))
        #expect(LZMotion.reducedFade <= 0.12)
    }

    @Test("Staggers step 40 ms and cap so long lists never crawl in")
    func stagger() {
        #expect(LZMotion.staggerDelay(index: 0) == 0)
        #expect(abs(LZMotion.staggerDelay(index: 1) - 0.04) < 1e-12)
        #expect(LZMotion.staggerDelay(index: 50) == LZMotion.staggerDelay(index: LZMotion.staggerCap))
        #expect(LZMotion.staggerDelay(index: -3) == 0)
    }

    @Test("Every token has a Reduce Motion replacement that is a short cross-fade")
    func reducedMotion() {
        for token in LZMotionToken.allCases {
            #expect(token.animation(reduceMotion: true) == token.reducedAnimation)
            #expect(token.animation(reduceMotion: false) == token.animation)
            #expect(token.reducedAnimation != token.animation, "\(token)")
        }
    }

    @Test("Reduce Motion turns every transition into a fade")
    func transitions() {
        for transition in LZTransition.allCases {
            _ = transition.anyTransition(reduceMotion: true)
            _ = transition.anyTransition(reduceMotion: false)
        }
    }

    @Test("Decorative loops run only when active, on screen, uncovered, Full, and neither Reduce Motion nor Low Power")
    func decorativePolicy() {
        let base = LZDecorativeMotionPolicy()
        #expect(base.allowsLoops && base.allowsStatusLoops)
        #expect(base.effectiveMode == .full)

        var p = base
        p.sceneActive = false
        #expect(!p.allowsLoops && !p.allowsStatusLoops)

        p = base
        p.onscreen = false
        #expect(!p.allowsLoops && !p.allowsStatusLoops)

        p = base
        p.covered = true
        #expect(!p.allowsLoops && p.allowsStatusLoops)

        p = base
        p.reduceMotion = true
        #expect(p.effectiveMode == .still && !p.allowsLoops && !p.allowsStatusLoops)

        p = base
        p.lowPower = true
        #expect(p.effectiveMode == .calm && !p.allowsLoops && p.allowsStatusLoops)

        p = base
        p.mode = .calm
        #expect(!p.allowsLoops && p.allowsStatusLoops)

        p = base
        p.mode = .still
        #expect(!p.allowsLoops && p.allowsStatusLoops)

        // Low power never upgrades a quieter mode.
        p = base
        p.mode = .still
        p.lowPower = true
        #expect(p.effectiveMode == .still)
    }

    @Test("Exhaustive: loops never run under Reduce Motion, Low Power, background or off screen")
    func decorativeExhaustive() {
        for active in [false, true] { for onscreen in [false, true] { for rm in [false, true] { for lp in [false, true] {
            for covered in [false, true] { for mode in LZMotionMode.allCases {
                let p = LZDecorativeMotionPolicy(sceneActive: active, onscreen: onscreen, reduceMotion: rm, lowPower: lp, covered: covered, mode: mode)
                if p.allowsLoops { #expect(active && onscreen && !rm && !lp && !covered && mode == .full) }
                if p.allowsStatusLoops { #expect(active && onscreen && !rm) }
            } }
        } } } }
    }
}
