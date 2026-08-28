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
#endif
