import XCTest
@testable import Termini

#if canImport(AppKit)
import AppKit

@MainActor
final class TerminiSurfaceBackgroundTests: XCTestCase {
    private func makeView(
        surfaceBackground: TerminiSurfaceBackground = .terminal
    ) -> SurfaceContainerView {
        _ = NSApplication.shared
        return SurfaceContainerView(runtime: .shared, surfaceBackground: surfaceBackground)
    }

    func testDefaultSurfaceBackgroundRemainsTerminal() {
        let view = makeView()

        XCTAssertEqual(view.surfaceBackground, .terminal)
        XCTAssertTrue(view.isOpaque)
        XCTAssertTrue(view.layer?.isOpaque == true)
        XCTAssertEqual(view.layer?.backgroundColor?.alpha ?? -1, 1)
    }

    func testTransparentSurfaceBackgroundPersistsThroughAppearanceChange() {
        let view = makeView(surfaceBackground: .transparent)

        view.terminalAppearance = .init(theme: .midnightBloom)

        XCTAssertEqual(view.surfaceBackground, .transparent)
        XCTAssertFalse(view.isOpaque)
        XCTAssertFalse(view.layer?.isOpaque ?? true)
        XCTAssertEqual(view.layer?.backgroundColor?.alpha ?? -1, 0)
    }
}

@MainActor
final class TerminiScrollingSurfaceBackgroundTests: XCTestCase {
    private func surface(in container: TerminiScrollingContainerView) -> SurfaceContainerView {
        guard let surface = container.documentView as? SurfaceContainerView else {
            XCTFail("Expected a native terminal surface document view.")
            fatalError("Missing terminal surface")
        }
        return surface
    }

    func testScrollingContainerDefaultsToTerminalBackground() {
        _ = NSApplication.shared
        let container = TerminiScrollingContainerView()
        let surface = surface(in: container)

        XCTAssertEqual(surface.surfaceBackground, .terminal)
        XCTAssertTrue(surface.isOpaque)
    }

    func testScrollingContainerPreservesTransparentBackgroundThroughAppearanceChange() {
        _ = NSApplication.shared
        let container = TerminiScrollingContainerView(surfaceBackground: .transparent)
        container.update(
            controller: nil,
            appearance: .init(theme: .midnightBloom),
            isRenderVisible: true,
            surfaceBackground: .transparent
        )
        let surface = surface(in: container)

        XCTAssertEqual(surface.surfaceBackground, .transparent)
        XCTAssertFalse(surface.isOpaque)
        XCTAssertEqual(surface.layer?.backgroundColor?.alpha ?? -1, 0)
    }
}
#elseif canImport(UIKit)
import UIKit

@MainActor
final class TerminiSurfaceBackgroundTests: XCTestCase {
    func testDefaultSurfaceBackgroundRemainsTerminal() {
        let view = SurfaceContainerView(runtime: .shared)

        XCTAssertEqual(view.surfaceBackground, .terminal)
        XCTAssertTrue(view.isOpaque)
        XCTAssertTrue(view.layer.isOpaque)
        XCTAssertEqual(view.backgroundColor?.cgColor.alpha ?? -1, 1)
        XCTAssertEqual(view.layer.backgroundColor?.alpha ?? -1, 1)
    }

    func testTransparentSurfaceBackgroundPersistsThroughAppearanceChange() {
        let view = SurfaceContainerView(runtime: .shared, surfaceBackground: .transparent)

        view.terminalAppearance = .init(theme: .midnightBloom)

        XCTAssertEqual(view.surfaceBackground, .transparent)
        XCTAssertFalse(view.isOpaque)
        XCTAssertFalse(view.layer.isOpaque)
        XCTAssertEqual(view.backgroundColor?.cgColor.alpha ?? -1, 0)
        XCTAssertEqual(view.layer.backgroundColor?.alpha ?? -1, 0)
    }
}

@MainActor
final class TerminiScrollingSurfaceBackgroundTests: XCTestCase {
    private func surface(in container: TerminiScrollingContainerView) -> SurfaceContainerView {
        guard let surface = container.subviews.first(where: { $0 is SurfaceContainerView }) as? SurfaceContainerView else {
            XCTFail("Expected a native terminal surface subview.")
            fatalError("Missing terminal surface")
        }
        return surface
    }

    func testScrollingContainerDefaultsToTerminalBackground() {
        let container = TerminiScrollingContainerView()
        let surface = surface(in: container)

        XCTAssertEqual(surface.surfaceBackground, .terminal)
        XCTAssertTrue(surface.isOpaque)
    }

    func testScrollingContainerPreservesTransparentBackgroundThroughAppearanceChange() {
        let container = TerminiScrollingContainerView(surfaceBackground: .transparent)
        container.update(
            controller: nil,
            showsSystemKeyboard: true,
            appearance: .init(theme: .midnightBloom),
            surfaceBackground: .transparent
        )
        let surface = surface(in: container)

        XCTAssertEqual(surface.surfaceBackground, .transparent)
        XCTAssertFalse(surface.isOpaque)
        XCTAssertEqual(surface.backgroundColor?.cgColor.alpha ?? -1, 0)
        XCTAssertEqual(surface.layer.backgroundColor?.alpha ?? -1, 0)
    }
}
#endif
