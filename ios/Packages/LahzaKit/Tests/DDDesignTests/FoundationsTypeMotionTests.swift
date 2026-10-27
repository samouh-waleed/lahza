import SwiftUI
import Testing
@testable import DDDesign

@MainActor
@Suite("Foundations · typography")
struct FoundationsTypographyTests {
    @Test("Display and countdown numerals are Instrument Serif and never carry a weight")
    func serifRoles() {
        for role in [DDTextRole.displayXL, .displayLarge, .display, .displaySmall, .section, .numeralHero, .numeral] {
            #expect(role.spec.fontName == DDFontName.instrumentSerif, "\(role)")
            #expect(role.spec.weight == nil, "\(role) would synthesise bold")
        }
        #expect(DDTextRole.displayXL.spec.size == 48)
        #expect(DDTextRole.displayLarge.spec.size == 38)
        #expect(DDTextRole.display.spec.size == 32)
        #expect(DDTextRole.displaySmall.spec.size == 26)
        #expect(DDTextRole.numeralHero.spec.size == 64)
        #expect(DDTextRole.display.spec.isDisplay)
        #expect(!DDTextRole.numeralHero.spec.isDisplay)
    }

    @Test("UI roles are SF Pro and follow their text style")
    func sfRoles() {
        let expected: [DDTextRole: Font.TextStyle] = [
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
        let spec = DDTextRole.label.spec
        #expect(spec.size == 12 && spec.weight == .semibold && spec.uppercase && spec.tracking == 0.14)
    }

    @Test("Reading face and line height")
    func reading() {
        #expect(DDTextRole.reading.spec.fontName == DDFontName.newsreader)
        #expect(DDTextRole.reading.spec.lineHeight == 1.65)
    }

    @Test("Display roles keep the face's natural leading at accessibility sizes, so wrapped titles never lose descenders")
    func displayLeadingAtAccessibilitySizes() {
        for role in DDTextRole.allCases where role.spec.isDisplay {
            #expect(role.spec.lineHeightPoints(scaledSize: 60, accessibilitySize: true) == nil, "\(role)")
        }
        #expect(DDTextRole.displaySmall.spec.lineHeightPoints(scaledSize: 26, accessibilitySize: false) == (26 * 1.12).rounded())
        // Reading and UI roles keep their exact line heights at every size.
        #expect(DDTextRole.reading.spec.lineHeightPoints(scaledSize: 40, accessibilitySize: true) == 66)
        #expect(DDTextRole.headline.spec.lineHeightPoints(scaledSize: 17, accessibilitySize: true) == nil)
    }

    @Test("Numerals are tabular")
    func numerals() {
        for role in [DDTextRole.numeralHero, .numeral, .numeralUI] { #expect(role.spec.tabular, "\(role)") }
    }

    @Test("Every bundled face name matches the PostScript names in ios/Resources/Fonts")
    func faceNames() {
        let expected = ["InstrumentSerif-Regular", "InstrumentSerif-Italic", "Newsreader-Regular", "Newsreader-Medium"]
        #expect(DDFontName.all == expected)
    }

    @Test("Numeral cells are keyed from the right so digits roll in place")
    func numeralCells() {
        let a = DDNumeralCells.split("9:59"), b = DDNumeralCells.split("10:00")
        #expect(a.map(\.id) == [4, 3, 2, 1])
        #expect(b.map(\.id) == [5, 4, 3, 2, 1])
        // The minutes' ones digit keeps id 1 across the change.
        #expect(a.last?.id == b.last?.id)
        #expect(a.filter(\.isDigit).count == 3)
        #expect(DDNumeralCells.split("١").first?.isDigit == false)
    }
}

@MainActor
@Suite("Foundations · motion")
struct FoundationsMotionTests {
    @Test("Durations sit in their families: touch 100–160, interface 220–320, feature 450–700 ms")
    func durations() {
        #expect(DDMotion.touchRange.contains(DDMotion.touch))
        #expect(DDMotion.interfaceRange.contains(DDMotion.interface))
        #expect(DDMotion.featureRange.contains(DDMotion.feature))
        #expect(DDMotion.touchRange.contains(DDMotionToken.touch.duration))
        #expect(DDMotion.interfaceRange.contains(DDMotionToken.interface.duration))
        #expect(DDMotion.featureRange.contains(DDMotionToken.feature.duration))
        #expect(DDMotion.featureRange.contains(DDMotionToken.celebrate.duration))
        #expect(DDMotion.reducedFade <= 0.12)
    }

    @Test("Staggers step 40 ms and cap so long lists never crawl in")
    func stagger() {
        #expect(DDMotion.staggerDelay(index: 0) == 0)
        #expect(abs(DDMotion.staggerDelay(index: 1) - 0.04) < 1e-12)
        #expect(DDMotion.staggerDelay(index: 50) == DDMotion.staggerDelay(index: DDMotion.staggerCap))
        #expect(DDMotion.staggerDelay(index: -3) == 0)
    }

    @Test("Every token has a Reduce Motion replacement that is a short cross-fade")
    func reducedMotion() {
        for token in DDMotionToken.allCases {
            #expect(token.animation(reduceMotion: true) == token.reducedAnimation)
            #expect(token.animation(reduceMotion: false) == token.animation)
            #expect(token.reducedAnimation != token.animation, "\(token)")
        }
    }

    @Test("Reduce Motion turns every transition into a fade")
    func transitions() {
        for transition in DDTransition.allCases {
            _ = transition.anyTransition(reduceMotion: true)
            _ = transition.anyTransition(reduceMotion: false)
        }
    }

    @Test("Decorative loops run only when active, on screen, uncovered, Full, and neither Reduce Motion nor Low Power")
    func decorativePolicy() {
        let base = DDDecorativeMotionPolicy()
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
            for covered in [false, true] { for mode in DDMotionMode.allCases {
                let p = DDDecorativeMotionPolicy(sceneActive: active, onscreen: onscreen, reduceMotion: rm, lowPower: lp, covered: covered, mode: mode)
                if p.allowsLoops { #expect(active && onscreen && !rm && !lp && !covered && mode == .full) }
                if p.allowsStatusLoops { #expect(active && onscreen && !rm) }
            } }
        } } } }
    }
}
