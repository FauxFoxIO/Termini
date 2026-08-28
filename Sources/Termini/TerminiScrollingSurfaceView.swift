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
    private let isRenderVisible: Bool

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        appearance: TerminiTerminalAppearance = .default,
        isRenderVisible: Bool = true
    ) {
        self.controller = controller
        self.showsSystemKeyboard = showsSystemKeyboard
        self.appearance = appearance
        self.isRenderVisible = isRenderVisible
    }

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        fontSize: Double? = nil
    ) {
        self.init(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: .init(fontSize: fontSize)
        )
    }

    public func makeUIView(context: Context) -> TerminiScrollingContainerView {
        let view = TerminiScrollingContainerView()
        view.update(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: appearance,
            isRenderVisible: isRenderVisible
        )
        return view
    }

    public func updateUIView(_ uiView: TerminiScrollingContainerView, context: Context) {
        uiView.update(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: appearance,
            isRenderVisible: isRenderVisible
        )
    }
}

/// Owns UIKit scrolling while keeping Ghostty's grid at the viewport size.
public final class TerminiScrollingContainerView: UIScrollView, UIScrollViewDelegate {
    private let surface = SurfaceContainerView(runtime: .shared)
    private var suppressOffsetChanges = false
    private var lastContentOffset: CGPoint = .zero
    private var lastAdjustedContentInset: UIEdgeInsets = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        isAccessibilityElement = false
        alwaysBounceHorizontal = true
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .automatic
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.maximumNumberOfTouches = 3

        surface.isNativeScrollHosted = true
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
        // Keep the native host exactly viewport-sized. Ghostty owns scrollback;
        // this content size only permits UIKit to deliver the pan gesture.
        contentSize = bounds.size
        resetContentOffsetIfInsetsChanged()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        resetContentOffsetIfInsetsChanged()
    }

    public override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        resetContentOffsetIfInsetsChanged()
    }

    func update(
        controller: TerminiTerminalController?,
        showsSystemKeyboard: Bool,
        appearance: TerminiTerminalAppearance,
        isRenderVisible: Bool
    ) {
        surface.showsSystemKeyboard = showsSystemKeyboard
        surface.terminalAppearance = appearance
        surface.isRenderVisible = isRenderVisible
        surface.bind(controller: controller)
        resetContentOffset()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !suppressOffsetChanges else { return }
        guard lastAdjustedContentInset == adjustedContentInset else {
            resetContentOffset()
            return
        }
        let delta = TerminiScrollTranslator.viewportDelta(
            from: lastContentOffset,
            to: scrollView.contentOffset
        )
        lastContentOffset = scrollView.contentOffset
        guard !delta.isZero else { return }
        surface.forwardNativeScrollDelta(delta)
        resetContentOffset()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        lastContentOffset = scrollView.contentOffset
        surface.becomeFirstResponder()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resetContentOffset() }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        resetContentOffset()
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        resetContentOffset()
    }

    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let viewportWidth = max(bounds.width, 1)
        let viewportHeight = max(bounds.height, 1)
        let delta: TerminiScrollDelta
        switch direction {
        case .up:
            delta = TerminiScrollDelta(x: 0, y: -Double(viewportHeight))
        case .down:
            delta = TerminiScrollDelta(x: 0, y: Double(viewportHeight))
        case .left:
            delta = TerminiScrollDelta(x: -Double(viewportWidth), y: 0)
        case .right:
            delta = TerminiScrollDelta(x: Double(viewportWidth), y: 0)
        @unknown default:
            return false
        }
        surface.forwardNativeScrollDelta(delta)
        return true
    }

    private func resetContentOffset() {
        let neutralOffset = TerminiScrollTranslator.neutralContentOffset(
            topInset: adjustedContentInset.top,
            leadingInset: adjustedContentInset.left
        )
        suppressOffsetChanges = true
        contentOffset = neutralOffset
        lastContentOffset = neutralOffset
        lastAdjustedContentInset = adjustedContentInset
        suppressOffsetChanges = false
    }

    private func resetContentOffsetIfInsetsChanged() {
        guard lastAdjustedContentInset != adjustedContentInset else { return }
        resetContentOffset()
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

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        appearance: TerminiTerminalAppearance = .default,
        isRenderVisible: Bool = true
    ) {
        self.controller = controller
        self.showsSystemKeyboard = showsSystemKeyboard
        self.appearance = appearance
        self.isRenderVisible = isRenderVisible
    }

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        fontSize: Double? = nil
    ) {
        self.init(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: .init(fontSize: fontSize)
        )
    }

    public func makeNSView(context: Context) -> TerminiScrollingContainerView {
        let view = TerminiScrollingContainerView()
        view.update(
            controller: controller,
            appearance: appearance,
            isRenderVisible: isRenderVisible
        )
        return view
    }

    public func updateNSView(_ nsView: TerminiScrollingContainerView, context: Context) {
        nsView.update(
            controller: controller,
            appearance: appearance,
            isRenderVisible: isRenderVisible
        )
    }
}

/// Keeps AppKit's native wheel event and Ghostty surface in one fixed viewport.
public final class TerminiScrollingContainerView: NSScrollView {
    private let surface = SurfaceContainerView(runtime: .shared)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        isRenderVisible: Bool
    ) {
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
