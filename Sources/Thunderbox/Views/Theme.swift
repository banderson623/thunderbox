import SwiftUI

/// "Out in the woods" palette — deep pine/moss background, warm brass + phosphor-green
/// accents drawn from the app icon (glowing terminals, brass pipes, damp forest).
enum Theme {
    // Backgrounds — warm blue-slate (indigo), lifted off pure black
    static let bgTop     = Color(red: 0.16, green: 0.175, blue: 0.235) // lifted slate blue
    static let bgBottom  = Color(red: 0.105, green: 0.115, blue: 0.165) // deep indigo
    static let console   = Color(red: 0.085, green: 0.095, blue: 0.14)  // terminal glass (bluish)

    // Surfaces (rows / panels) — slightly lifted from the background
    static let surface       = Color(red: 0.21, green: 0.23, blue: 0.30).opacity(0.72)
    static let surfaceStroke = Color(red: 0.58, green: 0.63, blue: 0.80).opacity(0.18)

    // Text
    static let textPrimary   = Color(red: 0.92, green: 0.93, blue: 0.90)  // warm off-white
    static let textSecondary = Color(red: 0.66, green: 0.70, blue: 0.80)  // blue-grey

    // Accents
    // Rich deep blue: the old phosphor green HSB(122°,0.47,0.86) with the hue rotated to
    // blue (~222°), saturation & brightness unchanged.
    static let accent = Color(red: 0.46, green: 0.58, blue: 0.86)   // rich blue
    static let amber  = Color(red: 0.96, green: 0.72, blue: 0.32)   // brass / warm glow
    static let danger = Color(red: 0.94, green: 0.42, blue: 0.36)   // ember red

    /// The main window gradient.
    static var woodsGradient: LinearGradient {
        LinearGradient(
            colors: [bgTop, bgBottom],
            startPoint: .top, endPoint: .bottom)
    }

    /// A subtle radial "clearing light" layered over the gradient.
    static var clearingGlow: RadialGradient {
        RadialGradient(
            colors: [accent.opacity(0.07), .clear],
            center: .init(x: 0.5, y: 0.32), startRadius: 0, endRadius: 520)
    }
}

/// Full-bleed woods background for a screen.
struct WoodsBackground: View {
    var body: some View {
        ZStack {
            Theme.woodsGradient
            Theme.clearingGlow
        }
        .ignoresSafeArea()
    }
}
