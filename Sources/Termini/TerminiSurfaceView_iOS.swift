#if canImport(UIKit)

import SwiftUI
import UIKit
import GhosttyKit

private func ghosttyMods(from modifiers: TerminiHardwareKeyModifiers) -> ghostty_input_mods_e {
    var raw = GHOSTTY_MODS_NONE.rawValue
    if modifiers.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if modifiers.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if modifiers.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if modifiers.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    if modifiers.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
    if modifiers.contains(.numericPad) { raw |= GHOSTTY_MODS_NUM.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
}

private func sendHardwareKey(
    surface: ghostty_surface_t,
    descriptor: TerminiHardwareKeyDescriptor,
    action: ghostty_input_action_e
) {
    let mods = ghosttyMods(from: descriptor.modifiers)
    let translatedMods = ghostty_surface_key_translation_mods(surface, mods)
    var consumedModsRaw = translatedMods.rawValue
    consumedModsRaw &= ~GHOSTTY_MODS_CTRL.rawValue
    consumedModsRaw &= ~GHOSTTY_MODS_SUPER.rawValue
    let consumedMods = ghostty_input_mods_e(rawValue: consumedModsRaw)
    var keyEvent = ghostty_input_key_s(
        action: action,
        mods: mods,
        consumed_mods: consumedMods,
        keycode: UInt32(descriptor.keyCode),
        text: nil,
        unshifted_codepoint: descriptor.unshiftedCodepoint,
        composing: false
    )

    if let text = descriptor.text {
        text.utf8CString.withUnsafeBufferPointer { buffer in
            keyEvent.text = buffer.baseAddress
            ghostty_surface_key(surface, keyEvent)
        }
    } else {
        ghostty_surface_key(surface, keyEvent)
    }
}

protocol TerminiSurfaceScrollbarDelegate: AnyObject {
    func surface(
        _ surface: SurfaceContainerView,
        didReceiveScrollbarState state: TerminiScrollbarState
    )
}

/// SwiftUI wrapper that embeds the live Ghostty surface on iOS.
public struct TerminiSurfaceView: UIViewRepresentable {
    private let controller: TerminiTerminalController?
    private let showsSystemKeyboard: Bool
    private let appearance: TerminiTerminalAppearance
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

    public final class Coordinator {
        fileprivate weak var controller: TerminiTerminalController?
        fileprivate weak var host: AnyObject?
        fileprivate var token: UInt64?
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> SurfaceContainerView {
        let view: SurfaceContainerView
        if let controller {
            let attachment = controller.attachToHost(context.coordinator)
            view = attachment.surface
            context.coordinator.controller = controller
            context.coordinator.host = context.coordinator
            context.coordinator.token = attachment.token
        } else {
            view = SurfaceContainerView(runtime: .shared, surfaceBackground: surfaceBackground)
        }
        view.showsSystemKeyboard = showsSystemKeyboard
        view.terminalAppearance = appearance
        view.bind(controller: controller)
        return view
    }

    public func updateUIView(_ uiView: SurfaceContainerView, context: Context) {
        if let current = context.coordinator.controller, current !== controller {
            if let token = context.coordinator.token, let host = context.coordinator.host {
                current.detachIfCurrent(token, host: host)
            }
            context.coordinator.token = nil
            context.coordinator.controller = nil
        }
        if let controller, context.coordinator.controller == nil {
            let attachment = controller.attachToHost(context.coordinator)
            context.coordinator.controller = controller
            context.coordinator.host = context.coordinator
            context.coordinator.token = attachment.token
        }
        uiView.showsSystemKeyboard = showsSystemKeyboard
        uiView.surfaceBackground = surfaceBackground
        uiView.terminalAppearance = appearance
        uiView.bind(controller: controller)
    }

    public static func dismantleUIView(_ uiView: SurfaceContainerView, coordinator: Coordinator) {
        if let token = coordinator.token, let controller = coordinator.controller,
           let host = coordinator.host {
            controller.detachIfCurrent(token, host: host)
        }
    }
}

/// UIView subclass that hosts the Ghostty surface and forwards basic iOS input.
public final class SurfaceContainerView: UIView, UIKeyInput, UITextInputTraits, UIGestureRecognizerDelegate {
    private let runtime: TerminiRuntime
    private var surface: ghostty_surface_t?
    /// Set once the surface has been created and ticked. Until then, terminal
    /// output is buffered rather than handed to `ghostty_surface_process_output`,
    /// which blocks the main thread on an un-ticked surface (the tick that drains
    /// it also runs on the main thread).
    private var surfaceIOReady = false
    private var restoredInitialSnapshot = false
    private var pendingOutput = Data()
    private var renderLink: CADisplayLink?
    private weak var controller: TerminiTerminalController?
    private var isHostAttached = true
    private var inputEnabled = true
    private let repeatCoordinator = TerminiHardwareKeyRepeatCoordinator()
    private var forwardedKeys: [UInt16: TerminiHardwareKeyDescriptor] = [:]
    weak var scrollbarStateDelegate: (any TerminiSurfaceScrollbarDelegate)?
    private var lastReportedSize: TerminiTerminalSize?
    private lazy var suppressedInputView = UIView(frame: .zero)
    private lazy var scrollPanGestureRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 3
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()
    /// Native scrolling containers own the pan recognizer so UIKit can participate in
    /// safe-area scrolling without competing with this surface's two-finger translator.
    var isNativeScrollHosted = false {
        didSet {
            guard oldValue != isNativeScrollHosted else { return }
            scrollPanGestureRecognizer.isEnabled = !isNativeScrollHosted
        }
    }

    public var keyboardType: UIKeyboardType = .asciiCapable
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var enablesReturnKeyAutomatically: Bool = false
    private var lastAppliedAppearance: TerminiTerminalAppearance = .default
    var surfaceBackground: TerminiSurfaceBackground {
        didSet {
            guard oldValue != surfaceBackground else { return }
            updateBackgroundColor()
        }
    }
    public var terminalAppearance: TerminiTerminalAppearance = .default {
        didSet {
            guard oldValue != terminalAppearance else { return }
            updateBackgroundColor()
            applyTerminalAppearanceIfNeeded(force: false)
        }
    }
    public var showsSystemKeyboard = true {
        didSet {
            guard oldValue != showsSystemKeyboard else { return }
            reloadInputViews()
        }
    }

    public var hasText: Bool { true }

    public override var inputView: UIView? {
        showsSystemKeyboard ? nil : suppressedInputView
    }

    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    private var displayScale: CGFloat {
        #if os(visionOS)
        // visionOS has no UIWindow screen scale; UIKit provides the display
        // scale through the view's traits once the view has been initialized.
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : 1.0
        #else
        return window?.screen.scale ?? UIScreen.main.scale
        #endif
    }

    init(
        runtime: TerminiRuntime,
        surfaceBackground: TerminiSurfaceBackground = .terminal
    ) {
        self.runtime = runtime
        self.surfaceBackground = surfaceBackground
        // Ghostty expects a non-zero host view so its internal IOSurface layer can size itself.
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        updateBackgroundColor()
        // Ghostty owns an IOSurfaceLayer below this view. Older known-good
        // GhosttyKit builds can size that layer to the full drawable before our
        // first layout pass; clip it so the terminal never paints over sibling
        // app chrome while synchronizeGhosttyLayerGeometry brings it in sync.
        clipsToBounds = true
        #if !os(visionOS)
        contentScaleFactor = UIScreen.main.scale
        #endif
        isMultipleTouchEnabled = true
        addGestureRecognizer(scrollPanGestureRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard terminalAppearance.theme == nil else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        applyTerminalAppearanceIfNeeded(force: true)
    }

    deinit {
        releaseForwardedKeys()
        renderLink?.invalidate()
        if let surface {
            runtime.unregisterSurface(surface)
            ghostty_surface_free(surface)
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            isHostAttached = false
            releaseForwardedKeys()
            setSurfaceFocus(false)
            if let surface {
                ghostty_surface_set_occlusion(surface, false)
            }
            renderLink?.invalidate()
            renderLink = nil
            return
        }
        isHostAttached = true
        createSurfaceIfNeeded()
        synchronizeGhosttyLayerGeometry()
        updateSurfaceSize()
        startRenderLoopIfNeeded()
        if controller == nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.becomeFirstResponder()
            }
        } else {
            restoreFocusIfNeeded()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        synchronizeGhosttyLayerGeometry()
        updateSurfaceSize()
    }

    public override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        guard inputEnabled else { return false }
        let ok = super.becomeFirstResponder()
        setSurfaceFocus(true)
        controller?.reportFocusChanged(true)
        runtime.keyboardDidChange()
        return ok
    }

    @discardableResult
    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        releaseForwardedKeys()
        setSurfaceFocus(false)
        controller?.reportFocusChanged(false)
        return ok
    }

    func setInputEnabled(_ enabled: Bool) {
        inputEnabled = enabled
        if !enabled {
            releaseForwardedKeys()
            _ = resignFirstResponder()
            setSurfaceFocus(false)
        }
    }

    func prepareForHostAttachment() {
        isHostAttached = true
        if let surface {
            ghostty_surface_set_occlusion(surface, window != nil)
        }
        if window != nil {
            createSurfaceIfNeeded()
            synchronizeGhosttyLayerGeometry()
            updateSurfaceSize()
            startRenderLoopIfNeeded()
            restoreFocusIfNeeded()
        }
    }

    func detachFromHost() {
        isHostAttached = false
        releaseForwardedKeys()
        if let surface {
            ghostty_surface_set_occlusion(surface, false)
        }
        setSurfaceFocus(false)
        if isFirstResponder {
            _ = resignFirstResponder()
        }
        renderLink?.invalidate()
        renderLink = nil
        removeFromSuperview()
    }

    var isSnapshotReady: Bool {
        surface != nil && surfaceIOReady
    }

    func requestSnapshot(
        userdata: UnsafeMutableRawPointer,
        callback: @escaping ghostty_surface_snapshot_cb
    ) -> Bool {
        guard let surface, surfaceIOReady else { return false }
        ghostty_surface_request_snapshot(surface, userdata, callback)
        return true
    }

    private func restoreFocusIfNeeded() {
        guard inputEnabled, isHostAttached,
              controller?.shouldRestoreFocus() == true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isHostAttached, self.window != nil,
                  self.controller?.shouldRestoreFocus() == true else { return }
            _ = self.becomeFirstResponder()
        }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if inputEnabled, isHostAttached {
            _ = becomeFirstResponder()
        }
    }

    @objc
    private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard inputEnabled, isHostAttached, let surface else { return }

        let translation = gesture.translation(in: self)
        let scale = displayScale

        switch gesture.state {
        case .began:
            _ = becomeFirstResponder()
            gesture.setTranslation(.zero, in: self)

        case .changed:
            let delta = TerminiScrollTranslator.iOSPanDelta(
                translationX: translation.x,
                translationY: translation.y,
                scale: scale
            )
            guard !delta.isZero else { return }
            forwardNativeScrollDelta(delta, surface: surface)
            gesture.setTranslation(.zero, in: self)

        case .ended, .cancelled, .failed:
            gesture.setTranslation(.zero, in: self)

        default:
            break
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handle(presses: presses, action: GHOSTTY_ACTION_PRESS) {
            return
        }
        super.pressesBegan(presses, with: event)
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handle(presses: presses, action: GHOSTTY_ACTION_RELEASE) {
            return
        }
        super.pressesEnded(presses, with: event)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releaseForwardedKeys()
        _ = presses
        _ = event
    }

    public func insertText(_ text: String) {
        guard inputEnabled, isHostAttached else { return }
        if controller?.forwardInputText(text) == true {
            return
        }
        sendText(text)
    }

    public func deleteBackward() {
        guard inputEnabled, isHostAttached else { return }
        if controller?.forwardDeleteBackward() == true {
            return
        }
        sendText("\u{7F}")
    }

    private func startRenderLoopIfNeeded() {
        guard renderLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(drawFrame))
        link.add(to: .main, forMode: .common)
        renderLink = link
    }

    @objc
    private func drawFrame() {
        guard isHostAttached, let surface else { return }
        ghostty_surface_draw(surface)
    }

    func bind(controller: TerminiTerminalController?) {
        if let current = self.controller, let controller, current === controller {
            return
        }
        if self.controller == nil, controller == nil {
            return
        }
        self.controller = controller
        controller?.bind(
            processRemoteOutput: { [weak self] data in
                self?.processRemoteOutput(data)
            },
            focus: { [weak self] in
                _ = self?.becomeFirstResponder()
            },
            blur: { [weak self] in
                _ = self?.resignFirstResponder()
            },
            currentSize: { [weak self] in
                self?.currentTerminalSize()
            },
            visibleText: { [weak self] in
                self?.visibleTerminalText()
            },
            diagnostics: { [weak self] in
                self?.surfaceDiagnostics()
            },
            setFindQuery: { [weak self] query in
                self?.applyBindingAction("search:\(query)")
            },
            findNext: { [weak self] in
                self?.applyBindingAction("navigate_search:next")
            },
            findPrevious: { [weak self] in
                self?.applyBindingAction("navigate_search:previous")
            },
            clearFind: { [weak self] in
                self?.applyBindingAction("end_search")
            }
        )
        reportSizeIfNeeded()
        reportDiagnostics()
    }

    private func createSurfaceIfNeeded() {
        guard surface == nil, let app = runtime.app else { return }

        let initialSnapshot = controller?.consumeInitialSnapshot()
        func createSurface(with snapshot: Data?) -> ghostty_surface_t? {
            var cfg = ghostty_surface_config_new()
            cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
            cfg.platform_tag = GHOSTTY_PLATFORM_IOS
            cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(self).toOpaque()
            ))
            cfg.scale_factor = Double(displayScale)
            cfg.font_size = Float(terminalAppearance.fontSize ?? 0)
            cfg.wait_after_command = false
            guard let snapshot, !snapshot.isEmpty else {
                return ghostty_surface_new(app, &cfg)
            }
            return snapshot.withUnsafeBytes { buffer in
                cfg.initial_snapshot = buffer.bindMemory(to: UInt8.self).baseAddress
                cfg.initial_snapshot_len = snapshot.count
                return ghostty_surface_new(app, &cfg)
            }
        }

        let firstAttempt = createSurface(with: initialSnapshot)
        let restored = firstAttempt != nil && initialSnapshot != nil
        var created = firstAttempt
        if created == nil, initialSnapshot != nil {
            controller?.reportInitialSnapshotRejected()
            created = createSurface(with: nil)
        }
        guard let created else { return }
        restoredInitialSnapshot = restored
        surface = created
        runtime.registerSurface(created, view: self)
        // `font_size` is part of the surface creation config, so it is already
        // active in the initial Ghostty font grid. Treat it as applied here to
        // avoid immediately replacing that grid with an identical one. Older
        // Metal renderers can otherwise leave cached cells pointing at the
        // retired glyph atlas until a full rebuild.
        if restored {
            lastAppliedAppearance = terminalAppearance
        } else {
            lastAppliedAppearance.fontSize = terminalAppearance.fontSize
        }
        synchronizeGhosttyLayerGeometry()
        setSurfaceFocus(controller == nil || controller?.shouldRestoreFocus() == true)
        updateSurfaceSize()
        ghostty_surface_refresh(created)
        ghostty_surface_draw(created)
        reportSizeIfNeeded()
        reportDiagnostics()
        scheduleInitialAppearance()
    }

    /// Mark the surface IO-ready and apply the initial appearance on a later
    /// main-actor turn. Feeding `ghostty_surface_process_output` before the app
    /// has ticked the freshly-created surface blocks the main thread on the
    /// surface's IO futex (the draining tick also runs on the main thread), so
    /// `processRemoteOutput` buffers until this runs.
    private func scheduleInitialAppearance() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.surface != nil else { return }
            self.runtime.tick()
            self.surfaceIOReady = true
            self.applyTerminalAppearanceIfNeeded(force: !self.restoredInitialSnapshot)
            self.flushPendingOutput()
            self.restoreFocusIfNeeded()
        }
    }

    private func flushPendingOutput() {
        guard surfaceIOReady, !pendingOutput.isEmpty else { return }
        let buffered = pendingOutput
        pendingOutput = Data()
        processRemoteOutput(buffered)
    }

    private func updateSurfaceSize() {
        guard isHostAttached, let surface else { return }
        let scale = Double(displayScale)
        ghostty_surface_set_content_scale(surface, scale, scale)
        let width = UInt32(bounds.width * scale)
        let height = UInt32(bounds.height * scale)
        ghostty_surface_set_size(surface, width, height)
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        reportSizeIfNeeded()
        reportDiagnostics()
    }

    private func setSurfaceFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func handleTransportWrite(_ data: Data) {
        controller?.forwardTransportWrite(data)
    }

    func reportFindStarted(_ query: String) {
        controller?.reportFindStarted(query)
    }

    func reportFindEnded() {
        controller?.reportFindEnded()
    }

    func reportFindTotal(_ total: Int?) {
        controller?.reportFindTotal(total)
    }

    func reportFindSelected(_ selected: Int?) {
        controller?.reportFindSelected(selected)
    }

    func forwardNativeScrollDelta(_ delta: TerminiScrollDelta, surface: ghostty_surface_t? = nil) {
        guard inputEnabled, isHostAttached,
              let surface = surface ?? self.surface, !delta.isZero else { return }
        ghostty_surface_mouse_scroll(
            surface,
            delta.x,
            delta.y,
            ghostty_input_scroll_mods_t(0b0000_0001)
        )
    }

    func receiveGhosttyScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        scrollbarStateDelegate?.surface(
            self,
            didReceiveScrollbarState: TerminiScrollbarState(
                total: total,
                offset: offset,
                len: len
            )
        )
    }

    private func sendText(_ text: String) {
        guard inputEnabled, isHostAttached, let surface else { return }
        let len = text.utf8CString.count
        guard len > 0 else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
    }

    private func processRemoteOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        // Buffer until the surface exists and has been ticked — feeding an
        // un-ticked surface blocks the main thread (see scheduleInitialAppearance).
        guard surfaceIOReady, let surface else {
            pendingOutput.append(data)
            return
        }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.bindMemory(to: CChar.self).baseAddress else { return }
            ghostty_surface_process_output(surface, ptr, UInt(data.count))
        }
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        reportDiagnostics()
    }

    private func applyTerminalAppearanceIfNeeded(force: Bool) {
        guard let surface else { return }
        var canCommitAppearanceState = true

        if force || lastAppliedAppearance.colorStyle != terminalAppearance.colorStyle {
            if let theme = resolvedTerminalTheme {
                ghostty_surface_set_color_scheme(surface, theme.ghosttyColorScheme)
                processRemoteOutput(Data(theme.applyEscapeSequence.utf8))
            } else if lastAppliedAppearance.colorStyle != .terminalDefault {
                ghostty_surface_set_color_scheme(surface, ambientGhosttyColorScheme)
                processRemoteOutput(Data(TerminiTerminalTheme.resetEscapeSequence.utf8))
            } else if force {
                ghostty_surface_set_color_scheme(surface, ambientGhosttyColorScheme)
            }
        }

        let fontSizeChanged = lastAppliedAppearance.fontSize != terminalAppearance.fontSize
        let fontFamilyChanged = lastAppliedAppearance.fontFamily != terminalAppearance.fontFamily
        let shouldApplyFontConfig = fontSizeChanged
            || fontFamilyChanged
            || (force && terminalAppearance.hasRuntimeFontOverride)

        if shouldApplyFontConfig {
            guard let config = runtime.makeSurfaceConfig(for: terminalAppearance) else {
                canCommitAppearanceState = false
                return
            }
            defer { ghostty_config_free(config) }

            ghostty_surface_update_config(surface, config)

            if !force, fontSizeChanged {
                scheduleFontSizeBindingUpdate()
            }

            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            reportSizeIfNeeded()
            reportDiagnostics()
        }

        if canCommitAppearanceState {
            lastAppliedAppearance = terminalAppearance
        }
    }

    private func updateBackgroundColor() {
        let isTerminalBackground = surfaceBackground == .terminal
        let color = resolvedTerminalTheme?.background ?? .init(hex: 0x000000)
        let backgroundColor = isTerminalBackground
            ? UIColor(
                red: CGFloat(color.red) / 255.0,
                green: CGFloat(color.green) / 255.0,
                blue: CGFloat(color.blue) / 255.0,
                alpha: 1.0
            )
            : UIColor.clear
        self.backgroundColor = backgroundColor
        isOpaque = isTerminalBackground
        layer.isOpaque = isTerminalBackground
        layer.backgroundColor = backgroundColor.cgColor
    }

    private var resolvedTerminalTheme: TerminiTerminalTheme? {
        switch terminalAppearance.colorStyle {
        case .terminalDefault:
            nil
        case .system:
            systemTerminalTheme
        case let .theme(theme):
            theme
        }
    }

    private var systemTerminalTheme: TerminiTerminalTheme {
        TerminiTerminalTheme(
            id: "system",
            name: "System",
            colorScheme: traitCollection.userInterfaceStyle == .dark ? .dark : .light,
            background: terminalColor(.systemBackground),
            foreground: terminalColor(.label),
            cursor: terminalColor(tintColor),
            selectionBackground: terminalColor(.systemGray4),
            selectionForeground: terminalColor(.label),
            ansiPalette: [
                terminalColor(.secondaryLabel),
                terminalColor(.systemRed),
                terminalColor(.systemGreen),
                terminalColor(.systemOrange),
                terminalColor(.systemBlue),
                terminalColor(.systemPurple),
                terminalColor(.systemTeal),
                terminalColor(.label),
                terminalColor(.tertiaryLabel),
                terminalColor(.systemPink),
                terminalColor(.systemMint),
                terminalColor(.systemYellow),
                terminalColor(.systemIndigo),
                terminalColor(.systemPurple),
                terminalColor(.systemCyan),
                terminalColor(.label)
            ]
        )
    }

    private func terminalColor(_ color: UIColor) -> TerminiTerminalColor {
        let resolved = color.resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .init(hex: 0x000000)
        }
        return TerminiTerminalColor(
            red: UInt8(min(max((red * 255).rounded(), 0), 255)),
            green: UInt8(min(max((green * 255).rounded(), 0), 255)),
            blue: UInt8(min(max((blue * 255).rounded(), 0), 255))
        )
    }

    private var ambientGhosttyColorScheme: ghostty_color_scheme_e {
        switch traitCollection.userInterfaceStyle {
        case .dark:
            GHOSTTY_COLOR_SCHEME_DARK
        default:
            GHOSTTY_COLOR_SCHEME_LIGHT
        }
    }

    private func applyBindingAction(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(
            surface,
            action,
            UInt(action.lengthOfBytes(using: .utf8))
        )
    }

    private func scheduleFontSizeBindingUpdate() {
        let action: String
        if let fontSize = terminalAppearance.fontSize {
            action = "set_font_size:\(String(format: "%.2f", min(max(fontSize, 1), 255)))"
        } else {
            action = "reset_font_size"
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyBindingAction(action)
            guard self.surface != nil else { return }
            ghostty_surface_refresh(self.surface)
            ghostty_surface_draw(self.surface)
            self.reportSizeIfNeeded()
            self.reportDiagnostics()
        }
    }

    private func currentTerminalSize() -> TerminiTerminalSize? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return TerminiTerminalSize(
            columns: Int(size.columns),
            rows: Int(size.rows),
            cellWidthPixels: Int(size.cell_width_px),
            cellHeightPixels: Int(size.cell_height_px)
        )
    }

    private func reportSizeIfNeeded() {
        guard let size = currentTerminalSize() else { return }
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        controller?.reportSizeChanged(size)
    }

    private func synchronizeGhosttyLayerGeometry() {
        let hostBounds = layer.bounds
        let scale = displayScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = hostBounds
            sublayer.contentsScale = scale
            sublayer.setNeedsDisplay()
        }
        CATransaction.commit()
    }

    private func reportDiagnostics() {
        guard let diagnostics = surfaceDiagnostics() else { return }
        controller?.reportDiagnosticsChanged(diagnostics)
    }

    private func surfaceDiagnostics() -> TerminiSurfaceDiagnostics? {
        let hostLayer = layer
        let sublayers = hostLayer.sublayers ?? []

        func describe(_ rect: CGRect) -> String {
            "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.size.width))x\(Int(rect.size.height))"
        }

        var lines = [
            "view.bounds \(describe(bounds))",
            "host.layer \(String(describing: type(of: hostLayer))) \(describe(hostLayer.bounds)) scale=\(hostLayer.contentsScale)",
            "window=\(window != nil) firstResponder=\(isFirstResponder) sublayers=\(sublayers.count)"
        ]

        for (index, sublayer) in sublayers.prefix(3).enumerated() {
            let contentsState = sublayer.contents == nil ? "nil" : "set"
            lines.append(
                "sub[\(index)] \(String(describing: type(of: sublayer))) frame=\(describe(sublayer.frame)) bounds=\(describe(sublayer.bounds)) scale=\(sublayer.contentsScale) contents=\(contentsState) hidden=\(sublayer.isHidden) opacity=\(sublayer.opacity)"
            )
        }

        if let size = currentTerminalSize() {
            lines.append("grid \(size.columns)x\(size.rows) cell=\(size.cellWidthPixels)x\(size.cellHeightPixels)")
        } else {
            lines.append("grid unavailable")
        }

        return TerminiSurfaceDiagnostics(lines: lines)
    }

    private func visibleTerminalText() -> String? {
        guard let surface, let size = currentTerminalSize() else { return nil }
        guard size.columns > 0, size.rows > 0 else { return nil }

        var text = ghostty_text_s(
            tl_px_x: 0,
            tl_px_y: 0,
            offset_start: 0,
            offset_len: 0,
            text: nil,
            text_len: 0
        )

        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(max(size.columns - 1, 0)),
                y: UInt32(max(size.rows - 1, 0))
            ),
            rectangle: false
        )

        guard ghostty_surface_read_text(surface, selection, &text),
              let base = text.text else {
            return nil
        }

        defer { ghostty_surface_free_text(surface, &text) }
        let data = Data(bytes: base, count: Int(text.text_len))
        return String(decoding: data, as: UTF8.self)
    }

    private func handle(presses: Set<UIPress>, action: ghostty_input_action_e) -> Bool {
        guard inputEnabled, isHostAttached else { return true }
        var ownsPress = false
        var hasTextOnlyPresses = true

        for press in presses {
            guard let key = press.key else { continue }
            switch route(for: key) {
            case .text:
                continue
            case let .raw(descriptor):
                ownsPress = true
                hasTextOnlyPresses = false
                switch action {
                case GHOSTTY_ACTION_PRESS:
                    guard forwardedKeys[descriptor.keyCode] == nil else { continue }
                    guard let surface else { continue }
                    sendHardwareKey(surface: surface, descriptor: descriptor, action: GHOSTTY_ACTION_PRESS)
                    forwardedKeys[descriptor.keyCode] = descriptor
                    repeatCoordinator.start(key: descriptor) { [weak self] descriptor in
                        guard let surface = self?.surface else { return }
                        sendHardwareKey(surface: surface, descriptor: descriptor, action: GHOSTTY_ACTION_REPEAT)
                    }
                case GHOSTTY_ACTION_RELEASE:
                    guard let forwarded = forwardedKeys.removeValue(forKey: descriptor.keyCode) else {
                        continue
                    }
                    repeatCoordinator.cancel(ifMatchingKeyCode: descriptor.keyCode)
                    if let surface {
                        sendHardwareKey(surface: surface, descriptor: forwarded, action: GHOSTTY_ACTION_RELEASE)
                    }
                default:
                    break
                }
            case .unsupported:
                ownsPress = true
                hasTextOnlyPresses = false
            }
        }

        return ownsPress || !hasTextOnlyPresses
    }

    private func route(for key: UIKey) -> TerminiHardwareKeyRoute {
        TerminiHardwareKeyTranslation.route(
            hidUsage: UInt16(truncatingIfNeeded: key.keyCode.rawValue),
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: TerminiHardwareKeyModifiers(uiKeyModifierFlags: key.modifierFlags)
        )
    }

    private func releaseForwardedKeys() {
        repeatCoordinator.cancel()
        let keys = Array(forwardedKeys.values)
        forwardedKeys.removeAll()
        guard let surface else { return }
        for key in keys {
            sendHardwareKey(surface: surface, descriptor: key, action: GHOSTTY_ACTION_RELEASE)
        }
    }
}

private extension TerminiHardwareKeyModifiers {
    init(uiKeyModifierFlags flags: UIKeyModifierFlags) {
        var modifiers = Self()
        if flags.contains(.alphaShift) { modifiers.insert(.capsLock) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.alternate) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.numericPad) { modifiers.insert(.numericPad) }
        self = modifiers
    }
}

private extension TerminiTerminalTheme {
    var ghosttyColorScheme: ghostty_color_scheme_e {
        switch colorScheme {
        case .dark:
            GHOSTTY_COLOR_SCHEME_DARK
        case .light:
            GHOSTTY_COLOR_SCHEME_LIGHT
        }
    }
}

#endif
