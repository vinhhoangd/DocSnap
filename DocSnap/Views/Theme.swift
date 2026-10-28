import SwiftUI
import UIKit

/// DocSnap's design tokens. Minimal "document grey + scan blue" look built on system
/// semantic colors, so light/dark mode and Increase Contrast work automatically.
/// The accent (scan blue) lives in the asset catalog: #2563EB light, #3B82F6 dark,
/// with higher-contrast variants; all pass WCAG AA against their backgrounds.
enum Theme {
    /// 4/8-pt spacing rhythm.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        /// Page thumbnails: paper has small corners.
        static let page: CGFloat = 6
        static let card: CGFloat = 14
        static let control: CGFloat = 12
    }

    /// Minimum touch target (HIG: 44×44 pt).
    static let minTarget: CGFloat = 44

    enum Motion {
        static let quick = Animation.snappy(duration: 0.2)
        static let standard = Animation.smooth(duration: 0.3)
    }
}

extension View {
    /// A sheet of paper: rounded corners, hairline edge and a soft, short shadow.
    func paperStyle(radius: CGFloat = Theme.Radius.page) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    /// Runs `animation` unless the person has turned on Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V, reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Short system haptics for discrete events (HIG: complement visual feedback, don't overuse).
@MainActor
enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// Pressed state that dims and slightly shrinks without changing layout bounds;
/// disabled buttons are visibly faded (a custom style doesn't get that for free).
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

extension ScanDocument {
    var pageCountText: String { pages.count == 1 ? "1 page" : "\(pages.count) pages" }
}
