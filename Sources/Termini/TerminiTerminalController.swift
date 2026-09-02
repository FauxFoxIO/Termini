import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import GhosttyKit

public struct TerminiTerminalSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cellWidthPixels: Int
    public let cellHeightPixels: Int

    public init(
        columns: Int,
        rows: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    ) {
        self.columns = columns
        self.rows = rows
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
    }
}

public struct TerminiSurfaceDiagnostics: Equatable, Sendable {
    public let lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }

    public var summary: String {
        lines.joined(separator: "\n")
    }
}

public struct TerminiTerminalFindState: Equatable, Sendable {
    public let query: String
    public let selectedMatchIndex: Int
    public let totalMatches: Int?
    public let isActive: Bool
    public let isReady: Bool

    public init(
        query: String = "",
        selectedMatchIndex: Int = 0,
        totalMatches: Int? = nil,
        isActive: Bool = false,
        isReady: Bool = false
    ) {
        self.query = query
        self.selectedMatchIndex = max(0, selectedMatchIndex)
        self.totalMatches = totalMatches.map { max(0, $0) }
        self.isActive = isActive
        self.isReady = isReady
    }
}

public enum TerminiTerminalSnapshotError: Error, Equatable, Sendable {
    case surfaceUnavailable
    case surfaceNotReady
    case ghosttyError
    case cancelled
}

public typealias TerminiSnapshotError = TerminiTerminalSnapshotError

@MainActor
public final class TerminiTerminalController {
    private var processRemoteOutputImpl: ((Data) -> Void)?
    private var focusImpl: (() -> Void)?
    private var blurImpl: (() -> Void)?
    private var currentSizeImpl: (() -> TerminiTerminalSize?)?
    private var visibleTextImpl: (() -> String?)?
    private var diagnosticsImpl: (() -> TerminiSurfaceDiagnostics?)?
    private var setFindQueryImpl: ((String) -> Void)?
    private var findNextImpl: (() -> Void)?
    private var findPreviousImpl: (() -> Void)?
    private var clearFindImpl: (() -> Void)?
    private var pendingOutputChunks: [Data] = []
    private var latestSize: TerminiTerminalSize?
    private var latestDiagnostics: TerminiSurfaceDiagnostics?
    private var isSizeNotificationScheduled = false
    private var isDiagnosticsNotificationScheduled = false

    private var durableSurface: SurfaceContainerView?
    private var initialSnapshot: Data?
    private var nextAttachmentToken: UInt64 = 0
    private var currentAttachment: Attachment?
    private var focusIntent = false
    private var pendingFindQuery = ""
    private var pendingFindNavigation: FindNavigation?

    private enum FindNavigation {
        case next
        case previous
    }

    private struct Attachment {
        weak var host: AnyObject?
        let token: UInt64
    }

    private final class SnapshotRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var didComplete = false

        func install(_ continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            if didComplete {
                lock.unlock()
                continuation.resume(throwing: TerminiTerminalSnapshotError.cancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func complete(_ result: Result<Data, Error>) {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        func cancel() {
            complete(.failure(TerminiTerminalSnapshotError.cancelled))
        }
    }

    public var onInputText: ((String) -> Void)?
    public var onDeleteBackward: (() -> Void)?
    public var onTransportWrite: ((Data) -> Void)?
    /// Called by the native surface when it becomes or resigns first responder.
    /// Keeping this callback on the controller avoids rebuilding SwiftUI closures on every update.
    public var onFocusChange: ((Bool) -> Void)?
    /// Called once when a supplied initial snapshot is rejected by Ghostty.
    /// The persisted bytes should be quarantined or removed by the owner.
    public var onInitialSnapshotRejected: (() -> Void)?
    public var onFindStateChange: ((TerminiTerminalFindState) -> Void)?

    public private(set) var findState = TerminiTerminalFindState()

    public var isInputEnabled: Bool = true {
        didSet {
            guard oldValue != isInputEnabled else { return }
            durableSurface?.setInputEnabled(isInputEnabled)
        }
    }

    public var onSizeChange: ((TerminiTerminalSize) -> Void)? {
        didSet {
            scheduleSizeNotificationIfNeeded()
        }
    }

    public var onDiagnosticsChange: ((TerminiSurfaceDiagnostics) -> Void)? {
        didSet {
            scheduleDiagnosticsNotificationIfNeeded()
        }
    }

    public init(initialSnapshot: Data? = nil) {
        self.initialSnapshot = initialSnapshot
    }

    public func processRemoteOutput(_ data: Data) {
        guard !data.isEmpty else { return }

        if let processRemoteOutputImpl {
            processRemoteOutputImpl(data)
        } else {
            pendingOutputChunks.append(data)
        }
    }

    public func focus() {
        focusIntent = true
        guard isInputEnabled else { return }
        focusImpl?()
    }

    public func blur() {
        focusIntent = false
        blurImpl?()
    }

    public func setFindQuery(_ query: String) {
        pendingFindQuery = query
        pendingFindNavigation = nil
        updateFindState {
            $0 = TerminiTerminalFindState(
                query: query,
                selectedMatchIndex: 0,
                totalMatches: nil,
                isActive: !query.isEmpty,
                isReady: $0.isReady
            )
        }
        setFindQueryImpl?(query)
    }

    public func findNext() {
        pendingFindNavigation = .next
        findNextImpl?()
    }

    public func findPrevious() {
        pendingFindNavigation = .previous
        findPreviousImpl?()
    }

    public func clearFind() {
        pendingFindQuery = ""
        pendingFindNavigation = nil
        updateFindState {
            $0 = TerminiTerminalFindState(isReady: $0.isReady)
        }
        clearFindImpl?()
    }

    public func exportSnapshot() async throws -> Data {
        guard let durableSurface else {
            throw TerminiTerminalSnapshotError.surfaceUnavailable
        }
        guard durableSurface.isSnapshotReady else {
            throw TerminiTerminalSnapshotError.surfaceNotReady
        }

        let request = SnapshotRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard !Task.isCancelled else {
                    request.cancel()
                    return
                }

                let userdata = Unmanaged.passRetained(request).toOpaque()
                guard durableSurface.requestSnapshot(
                    userdata: userdata,
                    callback: Self.snapshotCallback
                ) else {
                    Unmanaged<SnapshotRequest>.fromOpaque(userdata).release()
                    request.complete(.failure(TerminiTerminalSnapshotError.surfaceNotReady))
                    return
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    public func snapshot() async throws -> Data {
        try await exportSnapshot()
    }

    func attachToHost(_ host: AnyObject) -> (surface: SurfaceContainerView, token: UInt64) {
        if let currentAttachment, currentAttachment.host === host,
           let durableSurface {
            durableSurface.setInputEnabled(isInputEnabled)
            durableSurface.prepareForHostAttachment()
            return (durableSurface, currentAttachment.token)
        }

        if currentAttachment != nil {
            durableSurface?.detachFromHost()
        }

        let surface: SurfaceContainerView
        if let durableSurface {
            surface = durableSurface
        } else {
            surface = SurfaceContainerView(runtime: .shared)
            durableSurface = surface
            surface.bind(controller: self)
        }

        nextAttachmentToken &+= 1
        let token = nextAttachmentToken
        currentAttachment = Attachment(host: host, token: token)
        surface.setInputEnabled(isInputEnabled)
        surface.prepareForHostAttachment()
        addSurfaceToHost(surface, host: host)
        return (surface, token)
    }

    func detachIfCurrent(_ token: UInt64, host: AnyObject) {
        guard let currentAttachment,
              currentAttachment.token == token,
              currentAttachment.host === host else {
            return
        }
        self.currentAttachment = nil
        durableSurface?.detachFromHost()
    }

    func consumeInitialSnapshot() -> Data? {
        let snapshot = initialSnapshot
        initialSnapshot = nil
        return snapshot
    }

    func reportInitialSnapshotRejected() {
        onInitialSnapshotRejected?()
    }

    func shouldRestoreFocus() -> Bool {
        focusIntent && isInputEnabled
    }

    func reportFocusChanged(_ focused: Bool) {
        if focused {
            focusIntent = true
        }
        onFocusChange?(focused)
    }

    public func currentSize() -> TerminiTerminalSize? {
        currentSizeImpl?()
    }

    public func visibleText() -> String? {
        visibleTextImpl?()
    }

    public func diagnostics() -> TerminiSurfaceDiagnostics? {
        diagnosticsImpl?()
    }

    func bind(
        processRemoteOutput: @escaping (Data) -> Void,
        focus: @escaping () -> Void,
        blur: @escaping () -> Void,
        currentSize: @escaping () -> TerminiTerminalSize?,
        visibleText: @escaping () -> String?,
        diagnostics: @escaping () -> TerminiSurfaceDiagnostics?,
        setFindQuery: @escaping (String) -> Void,
        findNext: @escaping () -> Void,
        findPrevious: @escaping () -> Void,
        clearFind: @escaping () -> Void
    ) {
        processRemoteOutputImpl = processRemoteOutput
        focusImpl = focus
        blurImpl = blur
        currentSizeImpl = currentSize
        visibleTextImpl = visibleText
        diagnosticsImpl = diagnostics
        setFindQueryImpl = setFindQuery
        findNextImpl = findNext
        findPreviousImpl = findPrevious
        clearFindImpl = clearFind
        updateFindState {
            $0 = TerminiTerminalFindState(
                query: $0.query,
                selectedMatchIndex: $0.selectedMatchIndex,
                totalMatches: $0.totalMatches,
                isActive: $0.isActive,
                isReady: true
            )
        }
        if !pendingFindQuery.isEmpty {
            setFindQuery(pendingFindQuery)
        }
        if let pendingFindNavigation {
            switch pendingFindNavigation {
            case .next:
                findNext()
            case .previous:
                findPrevious()
            }
            self.pendingFindNavigation = nil
        }

        if let size = currentSize() {
            latestSize = size
            scheduleSizeNotificationIfNeeded()
        }

        if let diagnostics = diagnostics() {
            latestDiagnostics = diagnostics
            scheduleDiagnosticsNotificationIfNeeded()
        }

        guard !pendingOutputChunks.isEmpty else { return }
        let chunks = pendingOutputChunks
        pendingOutputChunks.removeAll(keepingCapacity: true)
        for chunk in chunks {
            processRemoteOutput(chunk)
        }
    }

    func reportSizeChanged(_ size: TerminiTerminalSize) {
        latestSize = size
        scheduleSizeNotificationIfNeeded()
    }

    func reportDiagnosticsChanged(_ diagnostics: TerminiSurfaceDiagnostics) {
        latestDiagnostics = diagnostics
        scheduleDiagnosticsNotificationIfNeeded()
    }

    func reportFindStarted(_ query: String) {
        updateFindState {
            $0 = TerminiTerminalFindState(
                query: query,
                selectedMatchIndex: 0,
                totalMatches: nil,
                isActive: true,
                isReady: true
            )
        }
    }

    func reportFindEnded() {
        updateFindState {
            $0 = TerminiTerminalFindState(isReady: $0.isReady)
        }
    }

    func reportFindTotal(_ total: Int?) {
        updateFindState {
            $0 = TerminiTerminalFindState(
                query: $0.query,
                selectedMatchIndex: $0.selectedMatchIndex,
                totalMatches: total,
                isActive: $0.isActive,
                isReady: $0.isReady
            )
        }
    }

    func reportFindSelected(_ selected: Int?) {
        updateFindState {
            $0 = TerminiTerminalFindState(
                query: $0.query,
                selectedMatchIndex: selected ?? 0,
                totalMatches: $0.totalMatches,
                isActive: $0.isActive,
                isReady: $0.isReady
            )
        }
    }

    func forwardInputText(_ text: String) -> Bool {
        guard isInputEnabled, let onInputText else { return false }
        onInputText(text)
        return true
    }

    func forwardDeleteBackward() -> Bool {
        guard isInputEnabled, let onDeleteBackward else { return false }
        onDeleteBackward()
        return true
    }

    func forwardTransportWrite(_ data: Data) {
        guard !data.isEmpty else { return }
        onTransportWrite?(data)
    }

    private func addSurfaceToHost(_ surface: SurfaceContainerView, host: AnyObject) {
        #if canImport(UIKit)
        if let host = host as? UIView, surface.superview !== host {
            host.addSubview(surface)
        }
        #elseif canImport(AppKit)
        if let host = host as? TerminiScrollingContainerView,
           let documentView = host.documentView,
           surface.superview !== documentView {
            documentView.addSubview(surface)
        } else if let host = host as? NSView, surface.superview !== host {
            host.addSubview(surface)
        }
        #endif
    }

    private static let snapshotCallback: ghostty_surface_snapshot_cb = {
        userdata, status, bytes, length in
        guard let userdata else { return }
        let request = Unmanaged<SnapshotRequest>.fromOpaque(userdata).takeRetainedValue()

        switch status {
        case GHOSTTY_SURFACE_SNAPSHOT_SUCCESS:
            guard let bytes, length > 0 else {
                request.complete(.failure(TerminiTerminalSnapshotError.ghosttyError))
                return
            }
            // The Ghostty callback owns borrowed bytes only for this call.
            request.complete(.success(Data(bytes: bytes, count: length)))
        case GHOSTTY_SURFACE_SNAPSHOT_CANCELLED:
            request.complete(.failure(TerminiTerminalSnapshotError.cancelled))
        default:
            request.complete(.failure(TerminiTerminalSnapshotError.ghosttyError))
        }
    }

    private func scheduleSizeNotificationIfNeeded() {
        guard latestSize != nil, !isSizeNotificationScheduled else { return }
        isSizeNotificationScheduled = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSizeNotificationScheduled = false
            guard let latestSize = self.latestSize else { return }
            self.onSizeChange?(latestSize)
        }
    }

    private func scheduleDiagnosticsNotificationIfNeeded() {
        guard latestDiagnostics != nil, !isDiagnosticsNotificationScheduled else { return }
        isDiagnosticsNotificationScheduled = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isDiagnosticsNotificationScheduled = false
            guard let latestDiagnostics = self.latestDiagnostics else { return }
            self.onDiagnosticsChange?(latestDiagnostics)
        }
    }

    private func updateFindState(
        _ update: (inout TerminiTerminalFindState) -> Void
    ) {
        var next = findState
        update(&next)
        guard next != findState else { return }
        findState = next
        onFindStateChange?(next)
    }
}
