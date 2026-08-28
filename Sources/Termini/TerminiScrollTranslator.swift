//
//  TerminiScrollTranslator.swift
//  Termini
//
//  Created by Ethan Lipnik on 8/27/26.
//

import CoreGraphics

struct TerminiScrollDelta: Equatable, Sendable {
    let x: Double
    let y: Double

    var isZero: Bool { x == 0 && y == 0 }
}

struct TerminiScrollbarState: Equatable, Sendable {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    func metrics(
        boundsHeight: CGFloat,
        adjustedContentInsetTop: CGFloat,
        adjustedContentInsetBottom: CGFloat
    ) -> TerminiScrollbarMetrics {
        TerminiScrollbarMetrics(
            state: self,
            boundsHeight: boundsHeight,
            adjustedContentInsetTop: adjustedContentInsetTop,
            adjustedContentInsetBottom: adjustedContentInsetBottom
        )
    }
}

struct TerminiScrollbarMetrics: Equatable, Sendable {
    let state: TerminiScrollbarState
    let scrollableLines: CGFloat
    let pointsPerLine: CGFloat
    let minY: CGFloat
    let span: CGFloat
    let maxY: CGFloat
    let contentSizeHeight: CGFloat
    let canonicalY: CGFloat

    var hasRange: Bool { span > 0 }

    init(
        state: TerminiScrollbarState,
        boundsHeight: CGFloat,
        adjustedContentInsetTop: CGFloat,
        adjustedContentInsetBottom: CGFloat
    ) {
        let viewportHeight = max(boundsHeight, 0)
        let scrollableLineCount = state.total >= state.len
            ? state.total - state.len
            : 0
        let scrollableLines = CGFloat(scrollableLineCount)
        let pointsPerLine = viewportHeight / max(CGFloat(state.len), 1)
        let minY = -adjustedContentInsetTop
        let span = state.len == 0 ? 0 : scrollableLines * pointsPerLine
        let maxY = minY + span
        let clampedOffset = state.len == 0
            ? 0
            : min(max(CGFloat(state.offset), 0), scrollableLines)

        self.state = state
        self.scrollableLines = scrollableLines
        self.pointsPerLine = pointsPerLine
        self.minY = minY
        self.span = span
        self.maxY = maxY
        self.contentSizeHeight = max(
            0,
            viewportHeight + span - adjustedContentInsetTop - adjustedContentInsetBottom
        )
        self.canonicalY = minY + clampedOffset * pointsPerLine
    }

    func clampedY(_ contentOffsetY: CGFloat) -> CGFloat {
        min(max(contentOffsetY, minY), maxY)
    }

    func overscrollTranslation(for contentOffsetY: CGFloat) -> CGFloat {
        if contentOffsetY < minY {
            return minY - contentOffsetY
        }
        if contentOffsetY > maxY {
            return maxY - contentOffsetY
        }
        return 0
    }
}

/// Shared scaling and sign rules for raw and native scrolling surfaces.
enum TerminiScrollTranslator {
    static func appKitDelta(
        scrollingDeltaX: Double,
        scrollingDeltaY: Double,
        hasPreciseDeltas: Bool
    ) -> TerminiScrollDelta {
        let scale = hasPreciseDeltas ? 2.0 : 1.0
        return TerminiScrollDelta(
            x: scrollingDeltaX * scale,
            y: scrollingDeltaY * scale
        )
    }

    static func iOSPanDelta(
        translationX: CGFloat,
        translationY: CGFloat,
        scale: CGFloat,
        precisionMultiplier: Double = 8
    ) -> TerminiScrollDelta {
        TerminiScrollDelta(
            x: Double(translationX * scale) * precisionMultiplier,
            y: Double(translationY * scale) * precisionMultiplier
        )
    }

    static func viewportDelta(from previous: CGPoint, to current: CGPoint) -> TerminiScrollDelta {
        TerminiScrollDelta(
            x: Double(current.x - previous.x),
            y: Double(current.y - previous.y)
        )
    }

    static func neutralContentOffset(topInset: CGFloat, leadingInset: CGFloat) -> CGPoint {
        CGPoint(x: -leadingInset, y: -topInset)
    }
}
