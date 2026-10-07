import Foundation
import KosmosIPC

/// Where this build came from, as script/bundle.sh stamps it into Info.plist: "main 7d65a13",
/// or a branch, or "+uncommitted" for a prototype (docs/INSTALL.md). A build not bundled has
/// none.
enum Build {
    static let source = Bundle.main.object(forInfoDictionaryKey: "KosmosSource") as? String

    static var isPrototype: Bool {
        guard let source else { return false }
        return source.range(of: #"^main [0-9a-f]+$"#, options: .regularExpression) == nil
    }

    /// `kosmos version`'s answer: "0.1.0 (main 7d65a13)".
    static var version: String { kosmosVersion + (source.map { " (\($0))" } ?? "") }

    static var description: String { "Kosmos " + version }
}
