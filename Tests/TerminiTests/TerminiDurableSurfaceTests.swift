import Foundation
import Testing
@testable import Termini

@Test
@MainActor
func contentInsetsClampNegativeValuesAndPreservePositiveViewportPadding() {
    let insets = TerminiTerminalContentInsets(horizontal: 18, vertical: 12)
    #expect(insets.horizontal == 18)
    #expect(insets.vertical == 12)
    #expect(TerminiTerminalContentInsets(horizontal: -1, vertical: -2) == .zero)
}

#if canImport(AppKit)
import AppKit

@Test
@MainActor
func durableSurfaceIdentitySurvivesHostReplacementAndRejectsStaleDetach() {
    guard NSApp != nil else { return }
    let controller = TerminiTerminalController()
    let firstHost = NSView()
    let secondHost = NSView()

    let firstAttachment = controller.attachToHost(firstHost)
    let surface = firstAttachment.surface
    secondHost.addSubview(surface)
    let secondAttachment = controller.attachToHost(secondHost)

    #expect(surface === secondAttachment.surface)
    #expect(firstAttachment.token < secondAttachment.token)

    controller.detachIfCurrent(firstAttachment.token, host: firstHost)
    #expect(surface.superview === secondHost)

    controller.detachIfCurrent(secondAttachment.token, host: secondHost)
    #expect(surface.superview == nil)
}

@Test
@MainActor
func focusIntentIsIndependentFromInputAvailability() {
    guard NSApp != nil else { return }
    let controller = TerminiTerminalController()
    controller.isInputEnabled = false
    controller.focus()
    controller.isInputEnabled = true

    let host = NSView()
    let attachment = controller.attachToHost(host)
    #expect(attachment.token > 0)
    #expect(controller.shouldRestoreFocus())

    controller.blur()
    #expect(!controller.shouldRestoreFocus())
}
#endif
