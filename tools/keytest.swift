// keytest: checks, on a managed Mac, whether a Right Command tap can be seen without permissions.
// Prints which permissions the terminal has, then every Right Command press and release for 60 s.
// Build: swiftc -O tools/keytest.swift -o .build/keytest
import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let rightCommand: CGKeyCode = 54

func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
let microphone: String = switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized: "yes"
case .denied: "denied"
case .restricted: "restricted"
default: "not asked yet"
}
print("""
keytest · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
Permissions of this terminal:
  Accessibility:    \(yesNo(AXIsProcessTrusted()))
  Input Monitoring: \(yesNo(CGPreflightListenEventAccess()))
  Microphone:       \(microphone)

Tap Right Command a few times, then try Right Command + C. Runs 60 seconds (Ctrl+C to stop).
""")

func isDown(_ key: CGKeyCode) -> Bool { CGEventSource.keyState(.combinedSessionState, key: key) }

var held = false, chord = false, pressedAt = Date(), seen = 0
let end = Date().addingTimeInterval(60)
while Date() < end {
    let down = isDown(rightCommand)
    if down && !held {
        held = true; chord = false; pressedAt = Date()
        print("Right Command: down")
    } else if down && held {
        // Any other key (or modifier) while held makes it a shortcut, not a dictation tap.
        if !chord, (0...127).contains(where: { CGKeyCode($0) != rightCommand && isDown(CGKeyCode($0)) }) {
            chord = true
        }
    } else if !down && held {
        held = false; seen += 1
        let ms = Int(Date().timeIntervalSince(pressedAt) * 1000)
        print("Right Command: up after \(ms) ms → \(chord ? "shortcut, ignored" : ms <= 1250 ? "TAP (would start dictation)" : "held too long, ignored")")
    }
    Thread.sleep(forTimeInterval: 0.02)
}
print(seen == 0
    ? "\nResult: no Right Command presses seen. Without permissions this Mac hides the key; use ⌃⌥Space or ask IT for Accessibility."
    : "\nResult: Right Command works without extra permissions (\(seen) presses seen).")
