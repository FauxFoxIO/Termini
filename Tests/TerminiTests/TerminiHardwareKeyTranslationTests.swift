//
//  TerminiHardwareKeyTranslationTests.swift
//  TerminiTests
//
//  Created by Ethan Lipnik on 8/26/26.
//

import XCTest
@testable import Termini

final class TerminiHardwareKeyTranslationTests: XCTestCase {
    func testHIDNavigationAndDeleteMapToMacVirtualKeyCodes() {
        let expected: [(UInt16, UInt16)] = [
            (42, 0x33), // Backspace.
            (79, 0x7C), // Right arrow.
            (80, 0x7B), // Left arrow.
            (81, 0x7D), // Down arrow.
            (82, 0x7E) // Up arrow.
        ]

        for (hidUsage, keyCode) in expected {
            XCTAssertEqual(
                TerminiHardwareKeyTranslation.macKeyCode(forHIDUsage: hidUsage),
                keyCode
            )
        }
    }

    func testPlainTextStaysOnUIKeyInputRoute() {
        let route = TerminiHardwareKeyTranslation.route(
            hidUsage: 4,
            characters: "a",
            charactersIgnoringModifiers: "a",
            modifiers: []
        )

        XCTAssertEqual(route, .text)
    }

    func testArrowsAndDeleteUseRawRoute() {
        for hidUsage in [42, 79, 80, 81, 82] {
            let route = TerminiHardwareKeyTranslation.route(
                hidUsage: UInt16(hidUsage),
                characters: "",
                charactersIgnoringModifiers: "",
                modifiers: []
            )

            guard case .raw = route else {
                return XCTFail("HID usage \(hidUsage) should be a raw terminal key.")
            }
        }
    }

    func testOptionDeletePreservesAlternateModifierAndMacKeyCode() {
        let route = TerminiHardwareKeyTranslation.route(
            hidUsage: 42,
            characters: "",
            charactersIgnoringModifiers: "",
            modifiers: [.alternate]
        )

        guard case let .raw(descriptor) = route else {
            return XCTFail("Option-Delete should be a raw terminal key.")
        }
        XCTAssertEqual(descriptor.keyCode, 0x33)
        XCTAssertTrue(descriptor.modifiers.contains(.alternate))
    }

    func testUnknownHIDUsageIsUnsupported() {
        let route = TerminiHardwareKeyTranslation.route(
            hidUsage: 0xFFFF,
            characters: "x",
            charactersIgnoringModifiers: "x",
            modifiers: []
        )

        XCTAssertEqual(route, .unsupported)
        XCTAssertNil(TerminiHardwareKeyTranslation.macKeyCode(forHIDUsage: 0xFFFF))
    }

    @MainActor
    func testRepeatCoordinatorGuardsGenerationAndCancellation() {
        let coordinator = TerminiHardwareKeyRepeatCoordinator()
        let key = TerminiHardwareKeyDescriptor(
            hidUsage: 79,
            keyCode: 0x7C,
            modifiers: [],
            text: nil,
            unshiftedCodepoint: 0
        )

        let initialGeneration = coordinator.generation
        coordinator.start(key: key) { _ in }
        XCTAssertEqual(coordinator.activeKey, key)
        XCTAssertNotEqual(coordinator.generation, initialGeneration)

        let generationAfterStart = coordinator.generation
        coordinator.cancel(ifMatchingKeyCode: 0x7B)
        XCTAssertEqual(coordinator.activeKey, key)
        XCTAssertEqual(coordinator.generation, generationAfterStart)

        coordinator.cancel(ifMatchingKeyCode: 0x7C)
        XCTAssertNil(coordinator.activeKey)
        XCTAssertNotEqual(coordinator.generation, generationAfterStart)
    }
}
