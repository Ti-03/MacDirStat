import SwiftUI

// Compatibility shims for macOS 26 Liquid Glass and macOS 14/15 APIs.
// On older OS versions these fall back to NSVisualEffectView-based materials.

// `glassEffect` / `.glass` button styles only exist in the macOS 26 SDK (Xcode 26,
// Swift 6.2). `#available` is a *runtime* check, it does not stop the compiler from
// needing the symbol, so on an older SDK these references fail to compile. Gate them
// at *compile* time with `#if compiler(>=6.2)`; the runtime `#available` stays inside
// so an Xcode-26 build still back-deploys correctly to macOS 14/15.
extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self.background(.ultraThinMaterial, in: Capsule())
        #endif
    }

    @ViewBuilder
    func glassCircle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
        #else
        self.background(.ultraThinMaterial, in: Circle())
        #endif
    }

    @ViewBuilder
    func glassCard(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }

    @ViewBuilder
    func glassInteractiveCard(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }

    @ViewBuilder
    func glassTintedCard(tint: Color, cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }

    @ViewBuilder
    func glassTintedInteractiveCapsule(tint: Color) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self.background(.ultraThinMaterial, in: Capsule())
        #endif
    }

    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }

    @ViewBuilder
    func glassProminentButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }
}

// MARK: - ContentUnavailableView backport

struct CompatContentUnavailableView: View {
    let title: String
    let systemImage: String
    let description: Text

    var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: description)
        } else {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                description
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }
}
