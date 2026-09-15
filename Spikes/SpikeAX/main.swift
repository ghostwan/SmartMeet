import AppKit
import ApplicationServices
import Foundation

// Diagnostic spike, not a production component: checks whether Microsoft
// Teams exposes enough in its accessibility tree to infer who's speaking and
// participant names, before investing in a real feature.
//
// Usage: start a real Teams meeting with at least two people taking turns
// speaking, then:
//
//     ./Scripts/bundle-spike.sh SpikeAX
//     open build/SpikeAX.app --args 60 2 > /tmp/spikeax.log
//     (join the meeting, have several people speak in turn)
//     cat /tmp/spikeax.log
//
// What we're looking for in the log: a node whose role/subrole/value changes
// specifically when the speaker changes, near a node carrying a participant's
// name. Without such a stable signal, the "accessibility" approach isn't
// usable and we'll have to fall back to something else.

func ensureAccessibilityPermission() -> Bool {
    // Literal string rather than the `kAXTrustedCheckOptionPrompt` constant:
    // the latter is a global C variable, deemed not concurrency-safe by Swift 6.
    let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
}

func findTeamsApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { app in
        guard app.activationPolicy == .regular else { return false }
        let name = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""
        return name.localizedCaseInsensitiveContains("teams")
            || bundleID.localizedCaseInsensitiveContains("teams")
    }
}

func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success, let value else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    guard result == .success, let children = value as? [AXUIElement] else { return [] }
    return children
}

struct DumpLimits {
    var maxDepth = 18
    var maxNodesPerSnapshot = 4000
}

func dump(
    _ element: AXUIElement,
    depth: Int,
    limits: DumpLimits,
    nodeCount: inout Int,
    into lines: inout [String]
) {
    guard depth <= limits.maxDepth, nodeCount < limits.maxNodesPerSnapshot else { return }
    nodeCount += 1

    let role = stringAttribute(element, kAXRoleAttribute as String) ?? "?"
    let subrole = stringAttribute(element, kAXSubroleAttribute as String)
    let title = stringAttribute(element, kAXTitleAttribute as String)
    let description = stringAttribute(element, kAXDescriptionAttribute as String)
    let value = stringAttribute(element, kAXValueAttribute as String)
    let help = stringAttribute(element, kAXHelpAttribute as String)
    let identifier = stringAttribute(element, "AXIdentifier")

    // Only keep nodes carrying text: the rest (pure layout containers) doesn't
    // help spot a participant's name or a speaking indicator, and would bloat
    // the dump with thousands of empty lines.
    let labels = [title, description, value, help, identifier].compactMap { $0 }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if !labels.isEmpty {
        let indent = String(repeating: "  ", count: depth)
        let subrolePart = subrole.map { " [\($0)]" } ?? ""
        let joined = labels.map { "\"\($0.prefix(120))\"" }.joined(separator: " | ")
        lines.append("\(indent)\(role)\(subrolePart): \(joined)")
    }

    for child in children(of: element) {
        dump(child, depth: depth + 1, limits: limits, nodeCount: &nodeCount, into: &lines)
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
let duration = arguments.count > 1 ? (Double(arguments[1]) ?? 30) : 30
let interval = arguments.count > 2 ? (Double(arguments[2]) ?? 2) : 2

print("SmartMeet — SpikeAX")
print("Diagnostic: periodic dump of Microsoft Teams' accessibility tree.")
print("Start a real Teams meeting BEFORE running this spike, with at least two")
print("participants taking turns speaking, to spot what changes in the dump")
print("when the speaker changes.")
print("")

guard ensureAccessibilityPermission() else {
    print("❌ Accessibility permission denied or not yet granted.")
    print("   System Settings › Privacy & Security › Accessibility › check SpikeAX,")
    print("   then relaunch this spike.")
    exit(1)
}

guard let teams = findTeamsApp() else {
    print("❌ Microsoft Teams not found among running applications.")
    print("   Launch Teams and join a meeting before running this spike.")
    exit(1)
}

print("✅ Teams found: pid \(teams.processIdentifier), bundle \(teams.bundleIdentifier ?? "?")")
print("Duration: \(Int(duration)) s, interval: \(interval) s")
print("")

let appElement = AXUIElementCreateApplication(teams.processIdentifier)
let start = Date()
var snapshotIndex = 0

while Date().timeIntervalSince(start) < duration {
    snapshotIndex += 1
    let elapsed = Date().timeIntervalSince(start)
    print("=== Snapshot \(snapshotIndex) — t+\(String(format: "%.1f", elapsed))s ===")

    var windowsValue: CFTypeRef?
    let windowsResult = AXUIElementCopyAttributeValue(
        appElement, kAXWindowsAttribute as CFString, &windowsValue
    )
    let windows = (windowsResult == .success ? windowsValue as? [AXUIElement] : nil) ?? []
    if windows.isEmpty {
        print("(no window found — does Teams have a meeting window open?)")
    }
    for (index, window) in windows.enumerated() {
        var lines: [String] = []
        var nodeCount = 0
        dump(window, depth: 0, limits: DumpLimits(), nodeCount: &nodeCount, into: &lines)
        print("--- window \(index) (\(nodeCount) nodes visited, \(lines.count) with text) ---")
        for line in lines { print(line) }
    }
    print("")

    Thread.sleep(forTimeInterval: interval)
}

print("Done.")
