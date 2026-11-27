import Foundation

public enum EconomistAccessError: LocalizedError, Sendable {
    case accessRequired

    public var errorDescription: String? {
        "Paperboy couldn’t read the full Economist article. Open it in a session with access, then try again."
    }
}
