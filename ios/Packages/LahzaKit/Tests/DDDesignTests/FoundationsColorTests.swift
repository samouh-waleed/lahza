import SwiftUI
import Testing
@testable import DDDesign

@MainActor
@Suite("Foundations · colour")
struct FoundationsColorTests {
    // MARK: Contrast contract

    @Test("Every text/background pair reaches 4.5:1, or 7:1 with Increase Contrast, in every appearance",
          arguments: DDAppearance.all)
    func textPairsPass(_ appearance: DDAppearance) {
        var failures: [String] = []
        for pair in DDContrastPairs.all {
            let ratio = pair.contrast(in: appearance)
            if ratio < appearance.minimumTextContrast {
                failures.append("\(pair) = \(String(format: "%.2f", ratio))")
            }
        }
        #expect(failures.isEmpty, "\(appearance): \(failures.joined(separator: ", "))")
    }

    @Test("The contract covers every paper and every text colour")
    func contractCoverage() {
        let texts = Set(DDContrastPairs.all.map(\.text))
        let backgrounds = Set(DDContrastPairs.all.map(\.background))
        for token in [DDColorToken.ink, .muted, .accent, .sageText, .goldText, .dangerText, .accentInk, .bg] {
            #expect(texts.contains(token), "\(token) is never checked as text")
        }
        for token in DDContrastPairs.papers + [.accent, .ink, .accentSoft, .sageSoft, .goldSoft, .dangerSoft] {
            #expect(backgrounds.contains(token), "\(token) is never checked as a background")
        }
        for tone in DDTone.allCases {
            #expect(DDContrastPairs.paperTexts.contains(tone.foreground), "\(tone) foreground is not a checked text colour")
        }
    }

    @Test("Increase Contrast makes form borders a real boundary (≥ 3:1 on every paper)")
    func increasedContrastBorders() {
        for dark in [false, true] {
            let appearance = DDAppearance(isDark: dark, increasedContrast: true)
            for paper in [DDColorToken.bg, .surface, .surface2] {
                let ratio = DDPalette.rgba(.lineSolid, appearance).contrast(with: DDPalette.rgba(paper, appearance))
                #expect(ratio >= 3, "lineSolid on \(paper) (\(appearance)) = \(ratio)")
            }
        }
    }

    @Test("Increase Contrast never lowers a text pair's contrast")
    func increasedContrastIsStronger() {
        for dark in [false, true] {
            let standard = DDAppearance(isDark: dark)
            let high = DDAppearance(isDark: dark, increasedContrast: true)
            for pair in DDContrastPairs.all where pair.base == nil {
                #expect(pair.contrast(in: high) >= pair.contrast(in: standard) - 0.01, "\(pair) (\(dark ? "dark" : "light"))")
            }
        }
    }

    // MARK: Palette values

    @Test("Paper and ink use the editorial ivory, bronze and charcoal palette")
    func brandValues() {
        let light: [DDColorToken: String] = [
            .bg: "#F8F6F0", .surface: "#FFFDF8", .surface2: "#EEEAE1", .ink: "#282821", .muted: "#69675F", .accent: "#6C5638",
            .gold: "#917040", .sage: "#486353", .danger: "#A1393D", .apricot: "#F2EBE1", .lilac: "#F0EDE6", .butter: "#F3EDDE",
            .mint: "#ECEEE7", .lineSolid: "#D8D4C9", .accentInk: "#FFFDF8", .accentDeep: "#282821",
        ]
        let dark: [DDColorToken: String] = [
            .bg: "#151614", .surface: "#20211E", .surface2: "#282925", .ink: "#F4F0E6", .muted: "#BAB7AD", .accent: "#DEC392",
            .gold: "#F1D28A", .sage: "#B2D9C3", .danger: "#FFA7A4", .apricot: "#292620", .lilac: "#272824", .butter: "#2B271F",
            .mint: "#242A24", .lineSolid: "#42443D", .accentInk: "#151614", .accentDeep: "#F0D9AF",
        ]
        for (token, hex) in light { #expect(DDPalette.rgba(token, .light).hex == hex, "light \(token)") }
        for (token, hex) in dark { #expect(DDPalette.rgba(token, .dark).hex == hex, "dark \(token)") }
    }

    @Test("Derived tints keep rules and accent surfaces quiet")
    func derivedTints() {
        #expect(DDPalette.rgba(.line, .light).alpha == 0.10)
        #expect(DDPalette.rgba(.line, .dark).alpha == 0.12)
        #expect(DDPalette.rgba(.line, .light).hex == "#282821")
        #expect(DDPalette.rgba(.accentSoft, .light).alpha == 0.10)
        #expect(DDPalette.rgba(.sageSoft, .light).alpha == 0.16)
        #expect(DDPalette.rgba(.dangerSoft, .dark).alpha == 0.14)
        #expect(DDPalette.rgba(.scrim, .light).hex == "#1C1422")
        #expect(DDPalette.rgba(.scrim, .light).alpha == 0.45)
    }

    @Test("Reduce Transparency: every token is opaque except the modal scrim, which strengthens")
    func reduceTransparencyIsOpaque() {
        for appearance in DDAppearance.all where appearance.reduceTransparency {
            for token in DDColorToken.allCases {
                let value = DDPalette.rgba(token, appearance)
                if token == .scrim {
                    #expect(value.alpha > DDPalette.rgba(.scrim, DDAppearance(isDark: appearance.isDark, increasedContrast: appearance.increasedContrast)).alpha)
                } else {
                    #expect(value.isOpaque, "\(token) is translucent under Reduce Transparency (\(appearance))")
                }
            }
        }
        // And in the standard appearance exactly the listed tokens are translucent.
        for token in DDColorToken.allCases {
            #expect(DDPalette.rgba(token, .light).isOpaque == !DDPalette.translucentTokens.contains(token), "\(token)")
        }
    }

    @Test("Opaque soft fills look the same as the translucent ones on the card surface")
    func opaqueFallbackMatchesOnSurface() {
        for dark in [false, true] {
            let surface = DDPalette.rgba(.surface, DDAppearance(isDark: dark))
            for token in [DDColorToken.accentSoft, .sageSoft, .goldSoft, .dangerSoft, .line] {
                let translucent = DDPalette.rgba(token, DDAppearance(isDark: dark)).composited(over: surface)
                let opaque = DDPalette.rgba(token, DDAppearance(isDark: dark, reduceTransparency: true))
                #expect(translucent.hex == opaque.hex, "\(token)")
            }
        }
    }

    // MARK: Colour maths

    @Test func hexRoundTrip() {
        #expect(DDRGBA(hex: 0x95641F).hex == "#95641F")
        #expect(DDRGBA(hexString: "#2b2233").hex == "#2B2233")
        #expect(DDRGBA(hexString: "FCF8F2").hex == "#FCF8F2")
        #expect(DDRGBA(hexString: "not a colour").hex == "#000000")
    }

    @Test func contrastExtremes() {
        let black = DDRGBA(hex: 0x000000), white = DDRGBA(hex: 0xFFFFFF)
        #expect(abs(black.contrast(with: white) - 21) < 1e-9)
        #expect(abs(white.contrast(with: black) - 21) < 1e-9)
        #expect(abs(white.contrast(with: white) - 1) < 1e-9)
        // Known WCAG value: #767676 on white is 4.54:1.
        #expect(abs(DDRGBA(hex: 0x767676).contrast(with: white) - 4.54) < 0.01)
    }

    @Test func compositingAndMixing() {
        let plum = DDRGBA(hex: 0x3D2B46)
        let paper = DDRGBA(hex: 0xFFFDFA)
        #expect(plum.opacity(0).composited(over: paper).hex == paper.hex)
        #expect(plum.opacity(1).composited(over: paper).hex == plum.hex)
        #expect(plum.mixed(with: paper, amount: 0).hex == plum.hex)
        #expect(plum.mixed(with: paper, amount: 1).hex == paper.hex)
        #expect(plum.mixed(with: paper, amount: 2).hex == paper.hex) // clamped
        // A translucent foreground is composited before measuring.
        let faint = DDRGBA(hex: 0x2B2233, alpha: 0.1)
        #expect(faint.contrast(with: paper) < 1.5)
    }

    @Test func nonFiniteInputIsClamped() {
        let c = DDRGBA(red: .nan, green: .infinity, blue: -3, alpha: 7)
        #expect(c.red == 0 && c.green == 0 && c.blue == 0 && c.alpha == 1)
    }

    // MARK: SwiftUI bridge

    @Test("DDColorStyle resolves from the environment: scheme, contrast and transparency")
    func styleResolvesFromEnvironment() {
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        #expect(DDAppearance(environment) == DDAppearance(isDark: true))
        environment._colorSchemeContrast = .increased
        environment._accessibilityReduceTransparency = true
        let appearance = DDAppearance(environment)
        #expect(appearance == DDAppearance(isDark: true, increasedContrast: true, reduceTransparency: true))

        let resolved = DDColorStyle(.muted).resolve(in: environment).resolve(in: environment)
        let expected = DDPalette.rgba(.muted, appearance)
        #expect(abs(Double(resolved.red) - expected.red) < 0.01)
        let opaqueSoft = DDColorStyle(.accentSoft).resolve(in: environment).resolve(in: environment)
        #expect(opaqueSoft.opacity == 1)
    }

    @Test func toneMapping() {
        #expect(DDTone.gold.foreground == .goldText)
        #expect(DDTone.sage.fill == .sageSoft)
        #expect(DDTone.neutral.fill == .surface2)
        #expect(DDWash.allCases.map(\.token) == [.apricot, .lilac, .butter, .mint])
    }
}
