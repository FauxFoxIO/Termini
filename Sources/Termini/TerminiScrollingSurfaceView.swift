//
//  TerminiScrollingSurfaceView.swift
//  Termini
//
//  Created by Ethan Lipnik on 8/27/26.
//

import SwiftUI

#if canImport(UIKit)

import UIKit

/// A native scroll-view host for a fixed-size Ghostty viewport.
public struct TerminiScrollingSurfaceView: UIViewRepresentable {
    private let controller: TerminiTerminalController?
    private let showsSystemKeyboard: Bool
    private let appearance: TerminiTerminalAppearance
    private let surfaceBackground: TerminiSurfaceBackground

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        appearance: TerminiTerminalAppearance = .default,
        isRenderVisible: Bool = true, // macOS-only render gate; ignored on iOS
        surfaceBackground: TerminiSurfaceBackground = .terminal
    ) {
        self.controller = controller
        self.showsSystemKeyboard = showsSystemKeyboard
        self.appearance = appearance
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

    public func makeUIView(context: Context) -> TerminiScrollingContainerView {
        let view = TerminiScrollingContainerView(surfaceBackground: surfaceBackground)
        view.update(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: appearance,
            surfaceBackground: surfaceBackground
        )
        return view
    }

    public func updateUIView(_ uiView: TerminiScrollingContainerView, context: Context) {
        uiView.update(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: appearance,
            surfaceBackground: surfaceBackground
        )
    }
}

/// Owns UIKit scrolling while keeping Ghostty's grid at the viewport size.
public final class TerminiScrollingContainerView: UIScrollView, UIScrollViewDelegate, TerminiSurfaceScrollbarDelegate {
    private let surface: SurfaceContainerView
    private var scrollbarState: TerminiScrollbarState?
    private var scrollbarMetrics: TerminiScrollbarMetrics?
    private var lastForwardedCanonicalY: CGFloat?
    private var isApplyingGhosttyScrollbar = false
    private var lastAdjustedContentInset: UIEdgeInsets = .zero
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        surface = SurfaceContainerView(runtime: .shared)
        super.init(frame: frame)
        configureSurface()
    }

    init(surfaceBackground: TerminiSurfaceBackground) {
        surface = SurfaceContainerView(runtime: .shared, surfaceBackground: surfaceBackground)
        super.init(frame: .zero)
        configureSurface()
    }

    private func configureSurface() {
        delegate = self
        isAccessibilityElement = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .automatic
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.maximumNumberOfTouches = 3

        surface.isNativeScrollHosted = true
        surface.scrollbarStateDelegate = self
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
            surface.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor),
            surface.bottomAnchor.constraint(equalTo: frameLayoutGuide.bottomAnchor),
            surface.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor),
            surface.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        refreshScrollGeometry()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        refreshScrollGeometry()
    }

    public override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        refreshScrollGeometry()
    }

    func update(
        controller: TerminiTerminalController?,
        showsSystemKeyboard: Bool,
        appearance: TerminiTerminalAppearance,
        surfaceBackground: TerminiSurfaceBackground
    ) {
        surface.showsSystemKeyboard = showsSystemKeyboard
        surface.surfaceBackground = surfaceBackground
        surface.terminalAppearance = appearance
        surface.bind(controller: controller)
        refreshScrollGeometry()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingGhosttyScrollbar,
              let metrics = scrollbarMetrics else {
            return
        }

        let clampedY = metrics.clampedY(scrollView.contentOffset.y)
        surface.transform = CGAffineTransform(
            translationX: 0,
            y: metrics.overscrollTranslation(for: scrollView.contentOffset.y)
        )

        if let previousY = lastForwardedCanonicalY {
            let delta = TerminiScrollTranslator.viewportDelta(
                from: CGPoint(x: 0, y: previousY),
                to: CGPoint(x: 0, y: clampedY)
            )
            if !delta.isZero {
                surface.forwardNativeScrollDelta(delta)
            }
        }
        lastForwardedCanonicalY = clampedY
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if let metrics = scrollbarMetrics {
            lastForwardedCanonicalY = metrics.clampedY(scrollView.contentOffset.y)
        }
        surface.becomeFirstResponder()
    }

    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let metrics = scrollbarMetrics, metrics.hasRange else { return false }
        let viewportHeight = max(bounds.height, 1)
        let targetY: CGFloat
        switch direction {
        case .up:
            targetY = metrics.clampedY(contentOffset.y - viewportHeight)
        case .down:
            targetY = metrics.clampedY(contentOffset.y + viewportHeight)
        case .left, .right, .next, .previous:
            return false
        @unknown default:
            return false
        }
        setContentOffset(
            CGPoint(x: contentOffset.x, y: targetY),
            animated: true
        )
        return true
    }

    private func refreshScrollGeometry() {
        let inset = adjustedContentInset
        guard lastAdjustedContentInset != inset
            || lastBoundsSize != bounds.size
            || scrollbarMetrics == nil else { return }
        lastAdjustedContentInset = inset
        lastBoundsSize = bounds.size

        if let scrollbarState {
            let metrics = scrollbarState.metrics(
                boundsHeight: bounds.height,
                adjustedContentInsetTop: inset.top,
                adjustedContentInsetBottom: inset.bottom
            )
            scrollbarMetrics = metrics
            contentSize = CGSize(width: bounds.width, height: metrics.contentSizeHeight)
            lastForwardedCanonicalY = metrics.clampedY(contentOffset.y)
            surface.transform = CGAffineTransform(
                translationX: 0,
                y: metrics.overscrollTranslation(for: contentOffset.y)
            )
        } else {
            // Keep the native host exactly viewport-sized until Ghostty supplies
            // a scrollbar model. The content size is only a gesture bridge.
            contentSize = CGSize(
                width: bounds.width,
                height: max(0, bounds.height - inset.top - inset.bottom)
            )
        }
    }

    func surface(
        _ surface: SurfaceContainerView,
        didReceiveScrollbarState state: TerminiScrollbarState
    ) {
        let metrics = state.metrics(
            boundsHeight: bounds.height,
            adjustedContentInsetTop: adjustedContentInset.top,
            adjustedContentInsetBottom: adjustedContentInset.bottom
        )
        let oldMetrics = scrollbarMetrics
        let transientOffsetY = contentOffset.y
        let transientTransform = surface.transform
        let isTopOverscroll = oldMetrics.map { transientOffsetY < $0.minY } ?? false
        let isBottomOverscroll = oldMetrics.map { transientOffsetY > $0.maxY } ?? false
        let isAtIncomingTop = metrics.canonicalY == metrics.minY
        let isAtIncomingBottom = metrics.hasRange && metrics.canonicalY == metrics.maxY
        let preserveTransientOverscroll = (isTopOverscroll && isAtIncomingTop)
            || (isBottomOverscroll && isAtIncomingBottom)

        isApplyingGhosttyScrollbar = true
        scrollbarState = state
        scrollbarMetrics = metrics
        contentSize = CGSize(width: bounds.width, height: metrics.contentSizeHeight)
        if preserveTransientOverscroll {
            contentOffset = CGPoint(x: contentOffset.x, y: transientOffsetY)
        } else {
            contentOffset = CGPoint(x: contentOffset.x, y: metrics.canonicalY)
        }
        isApplyingGhosttyScrollbar = false

        // A scrollbar action establishes a new canonical baseline. UIKit owns
        // any retained edge spring and its transient visual translation.
        lastForwardedCanonicalY = metrics.canonicalY
        if preserveTransientOverscroll {
            surface.transform = transientTransform
        } else {
            surface.transform = CGAffineTransform(
                translationX: 0,
                y: metrics.overscrollTranslation(for: contentOffset.y)
            )
        }
    }
}

#elseif canImport(AppKit)

import AppKit

/// A native scroll-view host for a fixed-size Ghostty viewport.
public struct TerminiScrollingSurfaceView: NSViewRepresentable {
    private let controller: TerminiTerminalController?
    private let showsSystemKeyboard: Bool
    private let appearance: TerminiTerminalAppearance
    private let isRenderVisible: Bool
    private let surfaceBackground: TerminiSurfaceBackground

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

    public func makeNSView(context: Context) -> TerminiScrollingContainerView {
        let view = TerminiScrollingContainerView(surfaceBackground: surfaceBackground)
        view.update(
            controller: controller,
            appearance: appearance,
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground
        )
        return view
    }

    public func updateNSView(_ nsView: TerminiScrollingContainerView, context: Context) {
        nsView.update(
            controller: controller,
            appearance: appearance,
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground
        )
    }
}

/// Keeps AppKit's native wheel event and Ghostty surface in one fixed viewport.
public final class TerminiScrollingContainerView: NSScrollView {
    private let surface: SurfaceContainerView

    override init(frame frameRect: NSRect) {
        surface = SurfaceContainerView(runtime: .shared)
        super.init(frame: frameRect)
        configureSurface()
    }

    init(surfaceBackground: TerminiSurfaceBackground) {
        surface = SurfaceContainerView(runtime: .shared, surfaceBackground: surfaceBackground)
        super.init(frame: .zero)
        configureSurface()
    }

    private func configureSurface() {
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        documentView = surface
        surface.translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        controller: TerminiTerminalController?,
        appearance: TerminiTerminalAppearance,
        isRenderVisible: Bool,
        surfaceBackground: TerminiSurfaceBackground
    ) {
        surface.surfaceBackground = surfaceBackground
        surface.terminalAppearance = appearance
        surface.isRenderVisible = isRenderVisible
        surface.bind(controller: controller)
        surface.frame = contentView.bounds
    }

    public override func layout() {
        super.layout()
        surface.frame = contentView.bounds
    }

    public override func scrollWheel(with event: NSEvent) {
        // NSScrollView remains the native safe-area/event host, while Ghostty keeps sole
        // ownership of scrollback and receives the exact raw wheel event translation.
        surface.forwardScrollWheelEvent(event)
    }
}

#endif
