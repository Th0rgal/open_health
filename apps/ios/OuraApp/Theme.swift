import SwiftUI
import UIKit

// thomas.md Quiet Ink: warm paper, serif titles, sans UI, mono numbers.
// Color is semantic, not decorative: gray when nothing is going on, green when
// something is genuinely good, orange/red when there is a problem.

enum Obs {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
        })
    }

    // Paper / ink — same values as thomas.md.
    static let paper = adaptive(light: 0xfbfaf6, dark: 0x131110)
    static let ink = adaptive(light: 0x26231e, dark: 0xefebe2)
    static let ink2 = adaptive(light: 0x57534b, dark: 0xcfc9bf)
    static let muted = adaptive(light: 0x6e695f, dark: 0xa8a195)
    static let link = adaptive(light: 0x2e2b26, dark: 0xe3ddd2)
    static let rule = adaptive(light: 0xe7e3da, dark: 0x2c2925)

    // Diagrams sit in the same ink family. Status uses the investing-post green/orange.
    static let chart = adaptive(light: 0x6e695f, dark: 0xa8a195)
    static let good = adaptive(light: 0x1baf7a, dark: 0x2ec48c)
    static let bad = adaptive(light: 0xeb6834, dark: 0xe07a4a)
    static let alert = adaptive(light: 0xc4472c, dark: 0xe06a4f)

    // Back-compat names. `teal` is the quiet chart color; `yellow` is a problem.
    static var teal: Color { chart }
    static var yellow: Color { bad }
    static var warn: Color { bad }
    static var black: Color { paper }
    static var base: Color { paper }
    static var baseLow: Color { paper }
    static var trace: Color { rule }

    static var canvas: some View { paper.ignoresSafeArea() }

    // Sleep stages keep distinct hues (deep / light / REM / wake). Other charts
    // stay gray unless a value is actually good or a problem.
    static let deep = adaptive(light: 0x104281, dark: 0x5598e7)
    static let light = adaptive(light: 0x6da7ec, dark: 0x9ec5f4)
    static let rem = adaptive(light: 0x1baf7a, dark: 0x2ec48c)
    static let wake = adaptive(light: 0xeda100, dark: 0xeda100)
    static func stage(_ s: Int) -> Color {
        switch s { case 1: return deep; case 2: return light; case 3: return rem; default: return wake }
    }

    /// Color a delta only when it is large enough to be worth noticing.
    static func tone(delta: Double?, goodWhenPositive: Bool = true, threshold: Double = 8) -> Color {
        guard let d = delta else { return chart }
        let isGood = d >= 0 ? goodWhenPositive : !goodWhenPositive
        if abs(d) < threshold { return chart }
        return isGood ? good : bad
    }

    static func debt(_ state: String) -> Color {
        switch state {
        case "none": return good
        case "low": return chart
        case "moderate": return bad
        case "high": return alert
        default: return chart
        }
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func prose(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct ObsTag: View {
    let text: String
    var icon: String? = nil
    init(_ text: String, icon: String? = nil) { self.text = text; self.icon = icon }
    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Obs.muted)
            }
            Text(text.uppercased())
                .font(Obs.mono(11, .medium))
                .tracking(1.6)
                .foregroundStyle(Obs.muted)
        }
    }
}

struct ObsCard: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Obs.paper, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Obs.rule, lineWidth: 1)
            )
    }
}

extension View {
    func obsCard(padding: CGFloat = 18, radius: CGFloat = 10) -> some View {
        modifier(ObsCard(padding: padding, radius: radius))
    }
}

struct ObsStat: View {
    let label: String
    let value: String
    var accent: Color = Obs.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Obs.mono(13)).foregroundStyle(Obs.ink2)
            Spacer(minLength: 16)
            Text(value).font(Obs.mono(15, .medium)).foregroundStyle(accent)
                .monospacedDigit()
        }
    }
}
