//
//  TerminiScrollingSurfaceView.swift
//  Termini
//
//  Created by Ethan Lipnik on 8/27/26.
//

import SwiftUI

/// Padding around the terminal viewport. The scroll host remains edge-to-edge;
/// only the drawable surface is inset, so Ghostty reports the inner grid size.
public struct TerminiTerminalContentInsets: Equatable, Sendable {
    public var horizontal: Double
    public var vertical: Double

    public init(horizontal: Double = 0, vertical: Double = 0) {
        self.horizontal = max(horizontal, 0)
        self.vertical = max(vertical, 0)
    }

    public static let zero = Self()
}

#if canImport(UIKit)

import UIKit

/// A native scroll-view host for a fixed-size Ghostty viewport.
public struct TerminiScrollingSurfaceView: UIViewRepresentable {
    private let controller: TerminiTerminalController?
    private let showsSystemKeyboard: Bool
    private let appearance: TerminiTerminalAppearance
    private let isRenderVisible: Bool
    private let surfaceBackground: TerminiSurfaceBackground
    private let contentInsets: TerminiTerminalContentInsets

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        appearance: TerminiTerminalAppearance = .default,
        isRenderVisible: Bool = true,
        surfaceBackground: TerminiSurfaceBackground = .terminal,
        contentInsets: TerminiTerminalContentInsets = .zero
    ) {
        self.controller = controller
        self.showsSystemKeyboard = showsSystemKeyboard
        self.appearance = appearance
        self.isRenderVisible = isRenderVisible
        self.surfaceBackground = surfaceBackground
        self.contentInsets = contentInsets
    }

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        fontSize: Double? = nil,
        surfaceBackground: TerminiSurfaceBackground = .terminal,
        isRenderVisible: Bool = true,
        contentInsets: TerminiTerminalContentInsets = .zero
    ) {
        self.init(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: .init(fontSize: fontSize),
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground,
            contentInsets: contentInsets
        )
    }

    public func makeUIView(context: Context) -> TerminiScrollingContainerView {
        let view = TerminiScrollingContainerView()
        view.update(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: appearance,
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground,
            contentInsets: contentInsets
        )
        return view
    }

    public func updateUIView(_ uiView: TerminiScrollingContainerView, context: Context) {
        uiView.update(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: appearance,
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground,
            contentInsets: contentInsets
        )
    }

    public static func dismantleUIView(
        _ uiView: TerminiScrollingContainerView,
        coordinator: ()) {
        uiView.detachCurrentSurface()
    }
}

/// Owns UIKit scrolling while keeping Ghostty's grid at the viewport size.
public final class TerminiScrollingContainerView: UIScrollView, UIScrollViewDelegate, TerminiSurfaceScrollbarDelegate {
    private weak var controller: TerminiTerminalController?
    private var attachmentToken: UInt64?
    private var activeSurface: SurfaceContainerView?
    private var legacySurface: SurfaceContainerView?
    private var terminalInsets = TerminiTerminalContentInsets.zero
    private var surfaceConstraints: [NSLayoutConstraint] = []
    private var surfaceBackground: TerminiSurfaceBackground = .terminal
    private var scrollbarState: TerminiScrollbarState?
    private var scrollbarMetrics: TerminiScrollbarMetrics?
    private var lastForwardedCanonicalY: CGFloat?
    private var isApplyingGhosttyScrollbar = false
    private var lastAdjustedContentInset: UIEdgeInsets = .zero
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSurface()
    }

    init(surfaceBackground: TerminiSurfaceBackground) {
        super.init(frame: .zero)
        self.surfaceBackground = surfaceBackground
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

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        isRenderVisible: Bool,
        surfaceBackground: TerminiSurfaceBackground,
        contentInsets: TerminiTerminalContentInsets
    ) {
        if let current = self.controller, current !== controller {
            detachCurrentSurface()
        }
        self.controller = controller
        self.terminalInsets = contentInsets
        self.surfaceBackground = surfaceBackground
        let previousSurface = activeSurface

        let surface: SurfaceContainerView
        if let controller {
            let attachment = controller.attachToHost(self)
            surface = attachment.surface
            attachmentToken = attachment.token
            activeSurface = surface
            legacySurface = nil
        } else if let legacySurface {
            surface = legacySurface
            activeSurface = surface
        } else {
            surface = SurfaceContainerView(runtime: .shared, surfaceBackground: surfaceBackground)
            legacySurface = surface
            activeSurface = surface
        }

        surface.isNativeScrollHosted = true
        surface.scrollbarStateDelegate = self
        surface.showsSystemKeyboard = showsSystemKeyboard
        surface.surfaceBackground = surfaceBackground
        surface.terminalAppearance = appearance
        surface.isRenderVisible = isRenderVisible
        if previousSurface !== surface {
            previousSurface?.removeFromSuperview()
        }
        surface.bind(controller: controller)
        installSurfaceIfNeeded(surface)
        updateSurfaceConstraints()
        layoutIfNeeded()
        refreshScrollGeometry()
    }

    func detachCurrentSurface() {
        if let controller, let attachmentToken {
            controller.detachIfCurrent(attachmentToken, host: self)
        } else {
            activeSurface?.removeFromSuperview()
        }
        attachmentToken = nil
        activeSurface = nil
        controller = nil
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateSurfaceConstraints()
        refreshScrollGeometry()
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        controller?.focus()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingGhosttyScrollbar,
              let metrics = scrollbarMetrics else {
            return
        }

        let clampedY = metrics.clampedY(scrollView.contentOffset.y)
        activeSurface?.transform = CGAffineTransform(
            translationX: 0,
            y: metrics.overscrollTranslation(for: scrollView.contentOffset.y)
        )

        if let previousY = lastForwardedCanonicalY {
            let delta = TerminiScrollTranslator.viewportDelta(
                from: CGPoint(x: 0, y: previousY),
                to: CGPoint(x: 0, y: clampedY)
            )
            if !delta.isZero {
                activeSurface?.forwardNativeScrollDelta(delta)
            }
        }
        lastForwardedCanonicalY = clampedY
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if let metrics = scrollbarMetrics {
            lastForwardedCanonicalY = metrics.clampedY(scrollView.contentOffset.y)
        }
        activeSurface?.becomeFirstResponder()
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
            activeSurface?.transform = CGAffineTransform(
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

    private func installSurfaceIfNeeded(_ surface: SurfaceContainerView) {
        if surface.superview !== self {
            surface.removeFromSuperview()
            addSubview(surface)
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        if surfaceConstraints.isEmpty {
            surfaceConstraints = [
                surface.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
                surface.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor),
                surface.bottomAnchor.constraint(equalTo: frameLayoutGuide.bottomAnchor)
            ]
            NSLayoutConstraint.activate(surfaceConstraints)
        }
    }

    private func updateSurfaceConstraints() {
        guard surfaceConstraints.count == 4 else { return }
        let horizontal = CGFloat(terminalInsets.horizontal)
        let vertical = CGFloat(terminalInsets.vertical)
        surfaceConstraints[0].constant = horizontal
        surfaceConstraints[1].constant = -horizontal
        surfaceConstraints[2].constant = vertical
        surfaceConstraints[3].constant = -vertical
        activeSurface?.setNeedsLayout()
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
    private let contentInsets: TerminiTerminalContentInsets

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        appearance: TerminiTerminalAppearance = .default,
        isRenderVisible: Bool = true,
        surfaceBackground: TerminiSurfaceBackground = .terminal,
        contentInsets: TerminiTerminalContentInsets = .zero
    ) {
        self.controller = controller
        self.showsSystemKeyboard = showsSystemKeyboard
        self.appearance = appearance
        self.isRenderVisible = isRenderVisible
        self.surfaceBackground = surfaceBackground
        self.contentInsets = contentInsets
    }

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        fontSize: Double? = nil,
        surfaceBackground: TerminiSurfaceBackground = .terminal,
        isRenderVisible: Bool = true,
        contentInsets: TerminiTerminalContentInsets = .zero
    ) {
        self.init(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: .init(fontSize: fontSize),
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground,
            contentInsets: contentInsets
        )
    }

    public func makeNSView(context: Context) -> TerminiScrollingContainerView {
        let view = TerminiScrollingContainerView(surfaceBackground: surfaceBackground)
        view.update(
            controller: controller,
            appearance: appearance,
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground,
            contentInsets: contentInsets
        )
        return view
    }

    public func updateNSView(_ nsView: TerminiScrollingContainerView, context: Context) {
        nsView.update(
            controller: controller,
            appearance: appearance,
            isRenderVisible: isRenderVisible,
            surfaceBackground: surfaceBackground,
            contentInsets: contentInsets
        )
    }

    public static func dismantleNSView(
        _ nsView: TerminiScrollingContainerView,
        coordinator: ()) {
        nsView.detachCurrentSurface()
    }
}

/// Keeps AppKit's native wheel event and Ghostty surface in one fixed viewport.
public final class TerminiScrollingContainerView: NSScrollView {
    private weak var controller: TerminiTerminalController?
    private var attachmentToken: UInt64?
    private var activeSurface: SurfaceContainerView?
    private var legacySurface: SurfaceContainerView?
    private var terminalInsets = TerminiTerminalContentInsets.zero
    private let surfaceBackground: TerminiSurfaceBackground

    override init(frame frameRect: NSRect) {
        surfaceBackground = .terminal
        super.init(frame: frameRect)
        configureSurface()
    }

    init(surfaceBackground: TerminiSurfaceBackground) {
        self.surfaceBackground = surfaceBackground
        super.init(frame: .zero)
        configureSurface()
    }

    private func configureSurface() {
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        documentView = FlippedContentView()
        documentView?.autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        controller: TerminiTerminalController?,
        appearance: TerminiTerminalAppearance,
        isRenderVisible: Bool,
        surfaceBackground: TerminiSurfaceBackground,
        contentInsets: TerminiTerminalContentInsets
    ) {
        if let current = self.controller, current !== controller {
            detachCurrentSurface()
        }
        self.controller = controller
        self.terminalInsets = contentInsets
        let previousSurface = activeSurface

        let surface: SurfaceContainerView
        if let controller {
            let attachment = controller.attachToHost(self)
            surface = attachment.surface
            attachmentToken = attachment.token
            activeSurface = surface
            legacySurface = nil
        } else if let legacySurface {
            surface = legacySurface
            activeSurface = surface
        } else {
            surface = SurfaceContainerView(runtime: .shared, surfaceBackground: surfaceBackground)
            legacySurface = surface
            activeSurface = surface
        }
        surface.surfaceBackground = surfaceBackground
        surface.terminalAppearance = appearance
        surface.isRenderVisible = isRenderVisible
        if previousSurface !== surface {
            previousSurface?.removeFromSuperview()
        }
        surface.bind(controller: controller)
        installSurfaceIfNeeded(surface)
        updateSurfaceFrame()
    }

    func detachCurrentSurface() {
        if let controller, let attachmentToken {
            controller.detachIfCurrent(attachmentToken, host: self)
        } else {
            activeSurface?.removeFromSuperview()
        }
        attachmentToken = nil
        activeSurface = nil
        controller = nil
    }

    public override func layout() {
        super.layout()
        updateSurfaceFrame()
    }

    public override func scrollWheel(with event: NSEvent) {
        // NSScrollView remains the native safe-area/event host, while Ghostty keeps sole
        // ownership of scrollback and receives the exact raw wheel event translation.
        activeSurface?.forwardScrollWheelEvent(event)
    }

    private func installSurfaceIfNeeded(_ surface: SurfaceContainerView) {
        guard let documentView else { return }
        guard surface.superview !== documentView else { return }
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = true
        documentView.addSubview(surface)
    }

    private func updateSurfaceFrame() {
        guard let documentView else { return }
        documentView.frame = contentView.bounds
        let horizontal = CGFloat(terminalInsets.horizontal)
        let vertical = CGFloat(terminalInsets.vertical)
        let bounds = documentView.bounds
        activeSurface?.frame = NSRect(
            x: bounds.minX + horizontal,
            y: bounds.minY + vertical,
            width: max(bounds.width - (horizontal * 2), 0),
            height: max(bounds.height - (vertical * 2), 0)
        )
    }
}

private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

#endif
