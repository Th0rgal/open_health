import SwiftUI
import UIKit

// thomas.md Quiet Ink on native SwiftUI. Warm paper, hairlines, serif titles,
// sans UI, mono numbers. Light and dark from the same tokens. No glass, no teal.

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

    // Paper / ink — same values as thomas.md (dark paper is one step from #121110).
    static let paper = adaptive(light: 0xfbfaf6, dark: 0x131110)
    static let ink = adaptive(light: 0x26231e, dark: 0xefebe2)       // headings
    static let ink2 = adaptive(light: 0x57534b, dark: 0xcfc9bf)      // body
    static let muted = adaptive(light: 0x6e695f, dark: 0xa8a195)
    static let link = adaptive(light: 0x2e2b26, dark: 0xe3ddd2)
    static let rule = adaptive(light: 0xe7e3da, dark: 0x2c2925)
    static let warn = adaptive(light: 0x8a5a32, dark: 0xc4a07a)

    // Back-compat names used across screens. Charts and tappable bits follow link
    // ink; "notice" follows warn; filled buttons sit on link with paper text.
    static var teal: Color { link }
    static var yellow: Color { warn }
    static var black: Color { paper }
    static var base: Color { paper }
    static var baseLow: Color { paper }
    static var trace: Color { rule }

    static var canvas: some View { paper.ignoresSafeArea() }

    // Sleep stages on warm paper: deep darkest → awake lightest, still four hues.
    static let deep = adaptive(light: 0x3f3b34, dark: 0x6a6358)
    static let light = adaptive(light: 0x8a8276, dark: 0x9a9286)
    static let rem = adaptive(light: 0x5a6a5c, dark: 0x7a8a7a)
    static let wake = adaptive(light: 0xc4b48a, dark: 0xd4c4a0)
    static func stage(_ s: Int) -> Color {
        switch s { case 1: return deep; case 2: return light; case 3: return rem; default: return wake }
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
                .tracking(2)
                .foregroundStyle(Obs.muted)
        }
    }
}

// Paper panel: hairline on paper, 10pt radius. No blur, no glass.
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
