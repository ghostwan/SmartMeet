import Foundation

/// Consommation de tokens d'un appel (ou d'une série d'appels cumulés) à un provider.
///
/// Les deux providers n'exposent pas la même précision : `opencode` (via Copilot)
/// renvoie des comptes exacts et un coût estimé, `ollama` ne renvoie que les tokens
/// (pas de coût, l'inférence étant locale). Tous les champs sont donc optionnels.
public struct TokenUsage: Sendable, Codable, Equatable {
    public var input: Int?
    public var output: Int?
    public var reasoning: Int?
    public var cacheWrite: Int?
    public var cacheRead: Int?
    /// Coût estimé en dollars, quand le provider le fournit (opencode/Copilot).
    public var costUSD: Double?

    public init(
        input: Int? = nil,
        output: Int? = nil,
        reasoning: Int? = nil,
        cacheWrite: Int? = nil,
        cacheRead: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.costUSD = costUSD
    }

    /// Somme de tout ce qui a transité (entrée + sortie + raisonnement + cache),
    /// c'est-à-dire ce qui est généralement facturé.
    public var total: Int {
        (input ?? 0) + (output ?? 0) + (reasoning ?? 0) + (cacheWrite ?? 0) + (cacheRead ?? 0)
    }

    /// Cumule deux mesures — utile quand une génération enchaîne plusieurs appels
    /// (découpage en morceaux, réparations de JSON invalide…).
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: sum(lhs.input, rhs.input),
            output: sum(lhs.output, rhs.output),
            reasoning: sum(lhs.reasoning, rhs.reasoning),
            cacheWrite: sum(lhs.cacheWrite, rhs.cacheWrite),
            cacheRead: sum(lhs.cacheRead, rhs.cacheRead),
            costUSD: sumDouble(lhs.costUSD, rhs.costUSD)
        )
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    private static func sumDouble(_ a: Double?, _ b: Double?) -> Double? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    /// Résumé lisible pour l'interface ou les logs headless.
    public var formatted: String {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.groupingSeparator = " "
        let tokens = numberFormatter.string(from: NSNumber(value: total)) ?? "\(total)"
        guard let costUSD else { return "\(tokens) tokens" }
        return "\(tokens) tokens (≈ \(String(format: "%.3f", costUSD)) $)"
    }
}

/// Texte généré par un provider, accompagné de sa consommation quand elle est connue.
public struct SummaryCompletion: Sendable {
    public let text: String
    public let usage: TokenUsage?

    public init(text: String, usage: TokenUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// Accumulateur cumulant les `TokenUsage` reçus au fil des appels d'une génération
/// (découpage en morceaux, réparations…). Les callbacks `onUsage` de
/// `SummaryGenerator.generate` sont `@Sendable` : cette classe évite d'avoir à
/// synchroniser soi-même une variable capturée à chaque appelant.
public final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated: TokenUsage?

    public init() {}

    public func add(_ usage: TokenUsage) {
        lock.lock()
        defer { lock.unlock() }
        accumulated = (accumulated ?? TokenUsage()) + usage
    }

    public var total: TokenUsage? {
        lock.lock()
        defer { lock.unlock() }
        return accumulated
    }
}
