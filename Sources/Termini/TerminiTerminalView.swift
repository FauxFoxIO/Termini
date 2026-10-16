import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SwiftUI wrapper for the live Ghostty surface.
public struct TerminiTerminalView: View {
    private let controller: TerminiTerminalController?
    private let showsSystemKeyboard: Bool
    private let appearance: TerminiTerminalAppearance
    private let surfaceBackground: TerminiSurfaceBackground
    // render gate for warm-cached surfaces (see TerminiSurfaceView).
    private let isRenderVisible: Bool

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        appearance: TerminiTerminalAppearance = .default,
        isRenderVisible: Bool = true,
        surfaceBackground: TerminiSurfaceBackground = .terminal
    ) {
        self.controller = controller
        self.showsSystemKeyboard = showsSystemKeyboard
        self.appearance = appearance
        self.isRenderVisible = isRenderVisible
        self.surfaceBackground = surfaceBackground
    }

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        fontSize: Double? = nil,
        surfaceBackground: TerminiSurfaceBackground = .terminal
    ) {
        self.init(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: .init(fontSize: fontSize),
            surfaceBackground: surfaceBackground
        )
    }

    public var body: some View {
        TerminiSurfaceView(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: appearance,
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground
        )
            .background(terminalBackground)
    }

    private var terminalBackground: Color {
        guard surfaceBackground == .terminal else {
            return .clear
        }

        if appearance.colorStyle == .system {
            #if canImport(UIKit)
            return Color(uiColor: .systemBackground)
            #elseif canImport(AppKit)
            return Color(nsColor: .windowBackgroundColor)
            #endif
        }

        guard let theme = appearance.theme else {
            return .black
        }

        return Color(
            red: Double(theme.background.red) / 255.0,
            green: Double(theme.background.green) / 255.0,
            blue: Double(theme.background.blue) / 255.0
        )
    }
}
