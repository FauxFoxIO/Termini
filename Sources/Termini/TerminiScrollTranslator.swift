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
