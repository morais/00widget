// Clicks one point on the Mac's screen, for driving the iOS Simulator's
// framebuffer from the host.
//
// The Simulator's device screen is not in the accessibility tree — macOS
// accessibility reaches Simulator.app's menus and windows, never the iOS UI
// drawn inside them — and `simctl` has no tap verb. A synthesised mouse event
// at the right screen point is the only way to press something on a locked
// device, which is what answering the Live Activities consent prompt needs.
//
// Callers map device pixels to screen points themselves; this takes screen
// points and nothing else, so it stays a tool rather than a policy.
//
//   swiftc -O -o sim-tap sim-tap.swift
//   sim-tap 1128 913

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let x = Double(arguments[1]),
      let y = Double(arguments[2])
else {
    FileHandle.standardError.write(Data("usage: sim-tap <x> <y>\n".utf8))
    exit(2)
}

let point = CGPoint(x: x, y: y)

// Move first, then click. A click posted at a point the cursor has never
// visited is delivered, but the window under it may not have updated its
// hover state, and the Simulator occasionally ignores the first press.
func post(_ type: CGEventType) {
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        FileHandle.standardError.write(Data("could not create \(type)\n".utf8))
        exit(1)
    }
    event.post(tap: .cghidEventTap)
}

post(.mouseMoved)
usleep(150_000)
post(.leftMouseDown)
usleep(90_000)
post(.leftMouseUp)
