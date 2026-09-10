import Foundation

/// Exact phrases are checked both by the UI and the Telegram session mutation methods.
enum DestructiveConfirmation {
    static let logout = "ABMELDEN"
    static let reset = "Ich möchte meine lokalen Telegram-Anmeldedaten wirklich löschen."
    static let photos = "Ich möchte die gesicherten Fotos und Videos vom iPhone löschen."
    static func matches(_ text: String, phrase: String) -> Bool { text == phrase }
}


