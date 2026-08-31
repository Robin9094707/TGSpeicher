import Foundation
import Combine
import UIKit
import TDLibFramework

final class TelegramClient: ObservableObject {
    @Published private(set) var authorizationStage: AuthorizationStage = .connecting
    @Published private(set) var accountName: String = "Telegram"
    @Published private(set) var savedMessagesChatID: Int64?
    @Published var lastError: String?

    private var clientID: Int32?
    private var isReceiving = false
    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var observers: [UUID: ([String: Any]) -> Void] = [:]
    private let lock = NSLock()
    private let receiveQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.tdlib.receive", qos: .userInitiated)

    // TDLib drives authorization through updateAuthorizationState. Keep a guard here so
    // setTdlibParameters can never be sent twice if multiple state messages arrive close together.
    private var tdlibParametersInFlight = false
    private var tdlibParametersConfigured = false

    private let apiIDKey = "telegram.api-id"
    private let apiHashKey = "telegram.api-hash"

    var hasAPICredentials: Bool {
        KeychainStore.get(apiIDKey) != nil && KeychainStore.get(apiHashKey) != nil
    }

    init() {
        if hasAPICredentials {
            start()
        } else {
            authorizationStage = .apiCredentials
        }
    }

    deinit {
        close()
    }

    func saveAPICredentials(apiIDText: String, apiHash: String) {
        let trimmedHash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiID = Int(apiIDText.trimmingCharacters(in: .whitespacesAndNewlines)), apiID > 0 else {
            lastError = "Please enter a valid Telegram API ID."
            return
        }
        guard trimmedHash.count >= 16 else {
            lastError = "Please enter your Telegram API hash from my.telegram.org."
            return
        }
        KeychainStore.set(String(apiID), for: apiIDKey)
        KeychainStore.set(trimmedHash, for: apiHashKey)
        lastError = nil
        start()
    }

    func resetAPICredentials() {
        close()
        KeychainStore.delete(apiIDKey)
        KeychainStore.delete(apiHashKey)
        KeychainStore.delete("tdlib.database-key")
        let fm = FileManager.default
        if let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? fm.removeItem(at: support.appendingPathComponent("TGSpeicher-TDLib", isDirectory: true))
        }
        tdlibParametersInFlight = false
        tdlibParametersConfigured = false
        accountName = "Telegram"
        savedMessagesChatID = nil
        authorizationStage = .apiCredentials
    }

    func setPhoneNumber(_ number: String) {
        let value = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        lastError = nil
        send([
            "@type": "setAuthenticationPhoneNumber",
            "phone_number": value,
            "settings": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
            } else {
                self.lastError = nil
            }
        }
    }

    func submitCode(_ code: String) {
        lastError = nil
        send(["@type": "checkAuthenticationCode", "code": code.trimmingCharacters(in: .whitespacesAndNewlines)]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
            } else {
                self.lastError = nil
            }
        }
    }

    func submitPassword(_ password: String) {
        lastError = nil
        send(["@type": "checkAuthenticationPassword", "password": password]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
            } else {
                self.lastError = nil
            }
        }
    }

    func logOut() {
        send(["@type": "logOut"]) { [weak self] response in
            self?.surfaceError(response)
        }
    }

    func send(_ request: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
        guard let clientID else {
            DispatchQueue.main.async { self.lastError = "Telegram is not connected yet." }
            return
        }
        var payload = request
        if let completion {
            let token = UUID().uuidString
            payload["@extra"] = token
            lock.lock()
            callbacks[token] = completion
            lock.unlock()
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let json = String(data: data, encoding: .utf8) else { return }
            td_send(clientID, json)
        } catch {
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }
    }

    @discardableResult
    func addUpdateObserver(_ observer: @escaping ([String: Any]) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return id
    }

    func removeUpdateObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    func clearError() {
        lastError = nil
    }

    private func start() {
        guard clientID == nil else { return }
        guard hasAPICredentials else {
            authorizationStage = .apiCredentials
            return
        }
        authorizationStage = .connecting
        tdlibParametersInFlight = false
        tdlibParametersConfigured = false

        let id = td_create_client_id()
        clientID = id
        isReceiving = true

        let logRequest: [String: Any] = ["@type": "setLogVerbosityLevel", "new_verbosity_level": 1]
        if let data = try? JSONSerialization.data(withJSONObject: logRequest),
           let json = String(data: data, encoding: .utf8) {
            _ = td_execute(json)
        }

        receiveQueue.async { [weak self] in
            self?.receiveLoop()
        }

        // Do not call getAuthorizationState here. TDLib guarantees that authorization is driven
        // through updateAuthorizationState; explicitly requesting it as well can cause the same
        // authorizationStateWaitTdlibParameters state to be handled twice.
    }

    private func close() {
        guard let clientID else { return }
        isReceiving = false
        if let data = try? JSONSerialization.data(withJSONObject: ["@type": "close"]),
           let json = String(data: data, encoding: .utf8) {
            td_send(clientID, json)
        }
        self.clientID = nil
        tdlibParametersInFlight = false
        tdlibParametersConfigured = false
    }

    private func receiveLoop() {
        while isReceiving {
            autoreleasepool {
                if let result = td_receive(0.5) {
                    let string = String(cString: result)
                    guard let data = string.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    handle(object)
                }
            }
        }
    }

    private func handle(_ response: [String: Any]) {
        let type = response["@type"] as? String ?? ""

        if let token = response["@extra"] as? String {
            lock.lock()
            let completion = callbacks.removeValue(forKey: token)
            lock.unlock()
            if let completion {
                DispatchQueue.main.async { completion(response) }
            }
        }

        lock.lock()
        let currentObservers = Array(observers.values)
        lock.unlock()
        if !currentObservers.isEmpty {
            DispatchQueue.main.async {
                currentObservers.forEach { $0(response) }
            }
        }

        if type == "updateAuthorizationState",
           let state = response["authorization_state"] as? [String: Any] {
            handleAuthorizationState(state)
        } else if type.hasPrefix("authorizationState") {
            handleAuthorizationState(response)
        } else if type == "error", response["@extra"] == nil {
            DispatchQueue.main.async {
                self.lastError = response["message"] as? String ?? "Telegram returned an unknown error."
            }
        }
    }

    private func handleAuthorizationState(_ state: [String: Any]) {
        let type = state["@type"] as? String ?? ""
        switch type {
        case "authorizationStateWaitTdlibParameters":
            configureTDLib()

        case "authorizationStateWaitPhoneNumber":
            tdlibParametersInFlight = false
            tdlibParametersConfigured = true
            DispatchQueue.main.async { self.lastError = nil }
            publish(stage: .phone)

        case "authorizationStateWaitCode":
            tdlibParametersInFlight = false
            tdlibParametersConfigured = true
            DispatchQueue.main.async { self.lastError = nil }

            var hint = "Enter the login code Telegram sent to you."
            if let codeInfo = state["code_info"] as? [String: Any],
               let codeType = codeInfo["type"] as? [String: Any],
               let codeTypeName = codeType["@type"] as? String {
                if codeTypeName.contains("TelegramMessage") {
                    hint = "Telegram sent the login code as a private message. Open an already signed-in Telegram app and check the verified ‘Telegram’ service chat — this is not an SMS."
                } else if codeTypeName.contains("Sms") {
                    hint = "Telegram sent the login code by SMS to your phone number."
                } else if codeTypeName.contains("Call") {
                    hint = "Telegram will provide the login code by phone call."
                } else if codeTypeName.contains("Email") {
                    hint = "Telegram sent the login code to the email address linked to your account."
                }
            }
            publish(stage: .code(hint: hint))

        case "authorizationStateWaitPassword":
            DispatchQueue.main.async { self.lastError = nil }
            let hint = state["password_hint"] as? String ?? ""
            publish(stage: .password(hint: hint))

        case "authorizationStateReady":
            tdlibParametersInFlight = false
            tdlibParametersConfigured = true
            DispatchQueue.main.async { self.lastError = nil }
            publish(stage: .ready)
            loadSelfAndSavedMessages()

        case "authorizationStateClosing", "authorizationStateLoggingOut":
            publish(stage: .connecting)

        case "authorizationStateClosed":
            tdlibParametersInFlight = false
            tdlibParametersConfigured = false
            publish(stage: .closed)

        case "authorizationStateWaitEmailAddress":
            publish(stage: .error("Telegram requires an email verification step for this login. This build currently supports phone code and 2FA password login."))

        case "authorizationStateWaitEmailCode":
            publish(stage: .error("Telegram requires an email verification code for this login. This build currently supports phone code and 2FA password login."))

        default:
            break
        }
    }

    private func configureTDLib() {
        guard !tdlibParametersConfigured, !tdlibParametersInFlight else { return }
        guard let apiIDString = KeychainStore.get(apiIDKey),
              let apiID = Int(apiIDString),
              let apiHash = KeychainStore.get(apiHashKey) else {
            publish(stage: .apiCredentials)
            return
        }

        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let root = support.appendingPathComponent("TGSpeicher-TDLib", isDirectory: true)
        let database = root.appendingPathComponent("database", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        try? fm.createDirectory(at: database, withIntermediateDirectories: true)
        try? fm.createDirectory(at: files, withIntermediateDirectories: true)

        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let params: [String: Any] = [
            "@type": "setTdlibParameters",
            "use_test_dc": false,
            "database_directory": database.path,
            "files_directory": files.path,
            "database_encryption_key": KeychainStore.databaseKey(),
            "use_file_database": true,
            "use_chat_info_database": true,
            "use_message_database": true,
            "use_secret_chats": false,
            "api_id": apiID,
            "api_hash": apiHash,
            "system_language_code": language,
            "device_model": UIDevice.current.model,
            "system_version": UIDevice.current.systemVersion,
            "application_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]

        tdlibParametersInFlight = true
        send(params) { [weak self] response in
            guard let self else { return }
            self.tdlibParametersInFlight = false
            if response["@type"] as? String == "error" {
                self.tdlibParametersConfigured = false
                self.surfaceError(response)
            } else {
                self.tdlibParametersConfigured = true
                self.lastError = nil
            }
        }
    }

    private func loadSelfAndSavedMessages() {
        send(["@type": "getMe"]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
                return
            }
            let first = response["first_name"] as? String ?? ""
            let last = response["last_name"] as? String ?? ""
            let name = ([first, last].filter { !$0.isEmpty }).joined(separator: " ")
            self.accountName = name.isEmpty ? "Telegram" : name

            guard let userID = Self.int64(response["id"]) else { return }
            self.send(["@type": "createPrivateChat", "user_id": userID, "force": false]) { [weak self] chat in
                guard let self else { return }
                if chat["@type"] as? String == "error" {
                    self.surfaceError(chat)
                    return
                }
                self.savedMessagesChatID = Self.int64(chat["id"])
            }
        }
    }

    private func surfaceError(_ response: [String: Any]) {
        guard response["@type"] as? String == "error" else { return }
        let message = response["message"] as? String ?? "Telegram returned an unknown error."
        lastError = message.replacingOccurrences(of: "_", with: " ").localizedCapitalized
    }

    private func publish(stage: AuthorizationStage) {
        DispatchQueue.main.async {
            self.authorizationStage = stage
        }
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
