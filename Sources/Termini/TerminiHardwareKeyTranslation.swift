//
//  TerminiHardwareKeyTranslation.swift
//  Termini
//
//  Created by Ethan Lipnik on 8/26/26.
//

import Foundation

/// The modifier state carried by a hardware keyboard press.
struct TerminiHardwareKeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: UInt16

    static let capsLock = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let alternate = Self(rawValue: 1 << 3)
    static let command = Self(rawValue: 1 << 4)
    static let numericPad = Self(rawValue: 1 << 5)
}

/// The macOS-compatible information needed to deliver a UIKit hardware key to Ghostty.
struct TerminiHardwareKeyDescriptor: Equatable, Hashable, Sendable {
    let hidUsage: UInt16
    let keyCode: UInt16
    let modifiers: TerminiHardwareKeyModifiers
    let text: String?
    let unshiftedCodepoint: UInt32
}

enum TerminiHardwareKeyRoute: Equatable, Sendable {
    /// UIKit should deliver the unmodified character through ``UIKeyInput``.
    case text
    /// The press is owned by the terminal and must be delivered as a Ghostty key event.
    case raw(TerminiHardwareKeyDescriptor)
    /// The HID usage is not part of the supported macOS virtual-key mapping.
    case unsupported
}

/// Maps UIKit HID usages and separates text input from terminal key events.
enum TerminiHardwareKeyTranslation {
    /// Converts a USB HID usage to the macOS virtual key code expected by Ghostty.
    ///
    /// The table mirrors Mirage's platform conversion table. Keeping this table
    /// local avoids making Termini depend on MirageKit while preventing an unknown
    /// HID usage from being interpreted as an unrelated macOS key.
    static func macKeyCode(forHIDUsage hidUsage: UInt16) -> UInt16? {
        hidToMacKeyCode[hidUsage]
    }

    static func route(
        hidUsage: UInt16,
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: TerminiHardwareKeyModifiers
    ) -> TerminiHardwareKeyRoute {
        guard let keyCode = macKeyCode(forHIDUsage: hidUsage) else {
            return .unsupported
        }

        let descriptor = TerminiHardwareKeyDescriptor(
            hidUsage: hidUsage,
            keyCode: keyCode,
            modifiers: modifiers,
            text: characters.isEmpty ? nil : characters,
            unshiftedCodepoint: charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0
        )

        // Modifier-bearing presses must go through Ghostty so control, option,
        // command, and shifted bindings retain their physical-key semantics.
        guard modifiers.isEmpty, !rawHIDUsages.contains(hidUsage) else {
            return .raw(descriptor)
        }

        // A recognized printable key with no modifiers remains ordinary text.
        // The UIKeyInput path handles IME and software-keyboard composition.
        guard !characters.isEmpty else {
            return .raw(descriptor)
        }
        return .text
    }

    private static let hidToMacKeyCode: [UInt16: UInt16] = [
        // Letters.
        4: 0x00, 5: 0x0B, 6: 0x08, 7: 0x02, 8: 0x0E, 9: 0x03,
        10: 0x05, 11: 0x04, 12: 0x22, 13: 0x26, 14: 0x28, 15: 0x25,
        16: 0x2E, 17: 0x2D, 18: 0x1F, 19: 0x23, 20: 0x0C, 21: 0x0F,
        22: 0x01, 23: 0x11, 24: 0x20, 25: 0x09, 26: 0x0D, 27: 0x07,
        28: 0x10, 29: 0x06,
        // Number row and punctuation.
        30: 0x12, 31: 0x13, 32: 0x14, 33: 0x15, 34: 0x17, 35: 0x16,
        36: 0x1A, 37: 0x1C, 38: 0x19, 39: 0x1D, 40: 0x24, 41: 0x35,
        42: 0x33, 43: 0x30, 44: 0x31, 45: 0x1B, 46: 0x18, 47: 0x21,
        48: 0x1E, 49: 0x2A, 51: 0x29, 52: 0x27, 53: 0x32, 54: 0x2B, 57: 0x39,
        55: 0x2F, 56: 0x2C,
        // Function, navigation, and arrows.
        58: 0x7A, 59: 0x78, 60: 0x63, 61: 0x76, 62: 0x60, 63: 0x61,
        64: 0x62, 65: 0x64, 66: 0x65, 67: 0x6D, 68: 0x67, 69: 0x6F,
        74: 0x73, 75: 0x74, 76: 0x75, 77: 0x77, 78: 0x79, 79: 0x7C,
        80: 0x7B, 81: 0x7D, 82: 0x7E,
        // Keypad.
        83: 0x47, 84: 0x4B, 85: 0x43, 86: 0x4E, 87: 0x45, 88: 0x4C,
        89: 0x53, 90: 0x54, 91: 0x55, 92: 0x56, 93: 0x57, 94: 0x58,
        95: 0x59, 96: 0x5B, 97: 0x5C, 98: 0x52, 99: 0x41, 103: 0x51,
        // Modifier keys.
        224: 0x3B, 225: 0x38, 226: 0x3A, 227: 0x37,
        228: 0x3E, 229: 0x3C, 230: 0x3D, 231: 0x36
    ]

    private static let rawHIDUsages: Set<UInt16> = [
        // Return, escape, backspace, tab, and caps lock.
        40, 41, 42, 43, 57,
        // Function keys and navigation.
        58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69,
        74, 75, 76, 77, 78, 79, 80, 81, 82,
        // Num lock and keypad enter.
        83, 88,
        // Left/right modifier keys.
        224, 225, 226, 227, 228, 229, 230, 231
    ]
}

/// Generates software key repeats for UIKit, which reports only press/release events.
@MainActor
final class TerminiHardwareKeyRepeatCoordinator {
    private(set) var generation: UInt64 = 0
    private(set) var activeKey: TerminiHardwareKeyDescriptor?
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    func start(
        key: TerminiHardwareKeyDescriptor,
        repeatAction: @escaping @MainActor (TerminiHardwareKeyDescriptor) -> Void
    ) {
        task?.cancel()
        generation &+= 1
        let token = generation
        activeKey = key

        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }

            guard let self, self.isCurrent(key: key, token: token) else { return }
            repeatAction(key)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }
                guard self.isCurrent(key: key, token: token) else { return }
                repeatAction(key)
            }
        }
    }

    func cancel(ifMatchingKeyCode keyCode: UInt16? = nil) {
        if let keyCode, activeKey?.keyCode != keyCode {
            return
        }
        task?.cancel()
        task = nil
        activeKey = nil
        generation &+= 1
    }

    private func isCurrent(key: TerminiHardwareKeyDescriptor, token: UInt64) -> Bool {
        generation == token && activeKey == key
    }
}
