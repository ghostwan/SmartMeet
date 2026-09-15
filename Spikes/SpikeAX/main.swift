import AppKit
import ApplicationServices
import Foundation

// Spike de diagnostic, pas un composant de production : sert à vérifier si
// Microsoft Teams expose dans son arbre d'accessibilité de quoi déduire qui parle
// et le nom des participants, avant d'investir dans une vraie fonctionnalité.
//
// Usage : lance une vraie réunion Teams avec au moins deux personnes qui parlent
// chacune leur tour, puis :
//
//     ./Scripts/bundle-spike.sh SpikeAX
//     open build/SpikeAX.app --args 60 2 > /tmp/spikeax.log
//     (rejoins la réunion, laisse plusieurs personnes parler à tour de rôle)
//     cat /tmp/spikeax.log
//
// Ce qu'on cherche dans le log : un nœud dont le rôle/sous-rôle/valeur change
// spécifiquement quand la personne qui parle change, à proximité d'un nœud portant
// le nom d'un participant. Sans un tel signal stable, l'approche « accessibilité »
// n'est pas exploitable et il faudra se rabattre sur autre chose.

func ensureAccessibilityPermission() -> Bool {
    // Chaîne littérale plutôt que la constante `kAXTrustedCheckOptionPrompt` : cette
    // dernière est une variable C globale, jugée non concurrency-safe par Swift 6.
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

    // Ne garde que les nœuds porteurs d'un texte : le reste (conteneurs de mise en
    // page purs) n'aide pas à repérer un nom de participant ou un indicateur de
    // parole, et gonflerait le dump de plusieurs milliers de lignes vides.
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

// MARK: - Entrée

let arguments = CommandLine.arguments
let duration = arguments.count > 1 ? (Double(arguments[1]) ?? 30) : 30
let interval = arguments.count > 2 ? (Double(arguments[2]) ?? 2) : 2

print("SmartMeet — SpikeAX")
print("Diagnostic : dump périodique de l'arbre d'accessibilité de Microsoft Teams.")
print("Lance une vraie réunion Teams AVANT de démarrer ce spike, avec au moins deux")
print("participants qui parlent chacun leur tour, pour repérer ce qui change dans")
print("le dump quand la personne qui parle change.")
print("")

guard ensureAccessibilityPermission() else {
    print("❌ Permission Accessibilité refusée ou pas encore accordée.")
    print("   Réglages Système › Confidentialité et sécurité › Accessibilité › coche SpikeAX,")
    print("   puis relance ce spike.")
    exit(1)
}

guard let teams = findTeamsApp() else {
    print("❌ Microsoft Teams introuvable parmi les applications en cours d'exécution.")
    print("   Lance Teams et rejoins une réunion avant de démarrer ce spike.")
    exit(1)
}

print("✅ Teams trouvé : pid \(teams.processIdentifier), bundle \(teams.bundleIdentifier ?? "?")")
print("Durée : \(Int(duration)) s, intervalle : \(interval) s")
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
        print("(aucune fenêtre trouvée — Teams a-t-il bien une fenêtre de réunion ouverte ?)")
    }
    for (index, window) in windows.enumerated() {
        var lines: [String] = []
        var nodeCount = 0
        dump(window, depth: 0, limits: DumpLimits(), nodeCount: &nodeCount, into: &lines)
        print("--- fenêtre \(index) (\(nodeCount) nœuds visités, \(lines.count) avec texte) ---")
        for line in lines { print(line) }
    }
    print("")

    Thread.sleep(forTimeInterval: interval)
}

print("Terminé.")
