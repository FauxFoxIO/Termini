//
//  TerminiScrollTranslatorTests.swift
//  TerminiTests
//
//  Created by Ethan Lipnik on 8/27/26.
//

import XCTest
@testable import Termini

final class TerminiScrollTranslatorTests: XCTestCase {
    func testAppKitDeltaPreservesSignAndPreciseScaling() {
        XCTAssertEqual(
            TerminiScrollTranslator.appKitDelta(
                scrollingDeltaX: -2,
                scrollingDeltaY: 3,
                hasPreciseDeltas: true
            ),
            TerminiScrollDelta(x: -4, y: 6)
        )
        XCTAssertEqual(
            TerminiScrollTranslator.appKitDelta(
                scrollingDeltaX: -2,
                scrollingDeltaY: 3,
                hasPreciseDeltas: false
            ),
            TerminiScrollDelta(x: -2, y: 3)
        )
    }

    func testIOSPanDeltaUsesTerminalPrecisionScale() {
        XCTAssertEqual(
            TerminiScrollTranslator.iOSPanDelta(
                translationX: -1.5,
                translationY: 2,
                scale: 2
            ),
            TerminiScrollDelta(x: -24, y: 32)
        )
    }

    func testViewportDeltaAndResetState() {
        XCTAssertEqual(
            TerminiScrollTranslator.viewportDelta(
                from: CGPoint(x: 8, y: -4),
                to: CGPoint(x: 3, y: 2)
            ),
            TerminiScrollDelta(x: -5, y: 6)
        )
        XCTAssertTrue(TerminiScrollDelta(x: 0, y: 0).isZero)
    }

    func testNeutralContentOffsetUsesAdjustedInsets() {
        let neutral = TerminiScrollTranslator.neutralContentOffset(
            topInset: 44,
            leadingInset: 12
        )
        XCTAssertEqual(neutral, CGPoint(x: -12, y: -44))
        XCTAssertEqual(
            TerminiScrollTranslator.viewportDelta(from: neutral, to: neutral),
            TerminiScrollDelta(x: 0, y: 0)
        )
    }

    func testScrollbarMetricsMapGhosttyEndpointsToNativeInsets() {
        let top = TerminiScrollbarState(total: 120, offset: 0, len: 20).metrics(
            boundsHeight: 400,
            adjustedContentInsetTop: 44,
            adjustedContentInsetBottom: 20
        )
        let bottom = TerminiScrollbarState(total: 120, offset: 100, len: 20).metrics(
            boundsHeight: 400,
            adjustedContentInsetTop: 44,
            adjustedContentInsetBottom: 20
        )

        XCTAssertEqual(top.minY, -44)
        XCTAssertEqual(top.maxY, 1_956)
        XCTAssertEqual(top.canonicalY, top.minY)
        XCTAssertEqual(bottom.canonicalY, bottom.maxY)
        XCTAssertEqual(top.contentSizeHeight, 2_336)
    }

    func testScrollbarMetricsExposeNoRangeWhenLenIsZero() {
        let metrics = TerminiScrollbarState(total: 120, offset: 80, len: 0).metrics(
            boundsHeight: 400,
            adjustedContentInsetTop: 44,
            adjustedContentInsetBottom: 20
        )

        XCTAssertFalse(metrics.hasRange)
        XCTAssertEqual(metrics.minY, -44)
        XCTAssertEqual(metrics.maxY, metrics.minY)
        XCTAssertEqual(metrics.canonicalY, metrics.minY)
    }

    func testScrollbarMetricsOnlyTranslateGenuineEdgeOverscroll() {
        let metrics = TerminiScrollbarState(total: 120, offset: 40, len: 20).metrics(
            boundsHeight: 400,
            adjustedContentInsetTop: 44,
            adjustedContentInsetBottom: 20
        )

        XCTAssertEqual(metrics.overscrollTranslation(for: metrics.minY + 10), 0)
        XCTAssertEqual(metrics.overscrollTranslation(for: metrics.maxY - 10), 0)
        XCTAssertEqual(metrics.overscrollTranslation(for: metrics.minY - 18), 18)
        XCTAssertEqual(metrics.overscrollTranslation(for: metrics.maxY + 18), -18)
    }

}
