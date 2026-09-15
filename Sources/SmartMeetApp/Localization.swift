import Foundation

/// Localizes a key that isn't a plain SwiftUI string literal (dynamic content
/// built from variables), where the implicit `LocalizedStringKey` interpolation
/// mechanism doesn't apply reliably.
///
/// The French source text doubles as both the lookup key and the fallback
/// value: if a translation is missing for the active language, the French
/// original is shown rather than a raw key like "review.delete.confirm".
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, value: key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
