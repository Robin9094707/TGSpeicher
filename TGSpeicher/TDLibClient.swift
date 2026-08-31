import Foundation
import Combine
import UIKit
import TDLibFramework

final class TelegramClient: ObservableObject {
    @Published private(set) var authorizationStage: AuthorizationStage = .connecting
    @Published private(set) var accountName: String = "Telegram"
    @Published private(set) var savedMessagesChatID: Int64?
    @Published private(set) var debugLines: [String] = []
    @Published private(set) var lastAuthorizationStateName: String = "Not started"
    @Published private(set) var lastActivityAt: Date?
    @Published var lastError: String?

    private var clientID: Int32?
    private var isReceiving = false
    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var observers: [UUID: ([String: Any]) -> Void] = [:]
    private let lock = NSLock()
    private let receiveQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.tdlib.receive", qos: .userInitiated)

    // TDLib drives authorization through updateAuthorizationState. These guards ensure
    // setTdlibParameters can never be submitted twice for the same client lifecycle.
    private var tdlibParametersInFlight = false
    private var tdlibParametersConfigured = false
    private var startGeneration = UUID()

    private let apiIDKey = "telegram.api-id"
    private let apiHashKey = "telegram.api-hash"

    var hasAPICredentials: Bool {
        KeychainStore.get(apiIDKey) != nil && KeychainStore.get(apiHashKey) != nil
    }

    var debugText: String {
        debugLines.joined(separator: "\n")
    }

    var clientDescription: String {
        if let clientID { return "Client \(clientID)" }
        return "No active client"
    }

    init() {
        appendDebug("TGSpeicher \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        if hasAPICredentials {
            appendDebug("API credentials found in local Keychain")
            start()
        } else {
            appendDebug("No API credentials stored")
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

        appendDebug("Saving API credentials to this-device-only Keychain")
        KeychainStore.set(String(apiID), for: apiIDKey)
        KeychainStore.set(trimmedHash, for: apiHashKey)
        lastError = nil
        start()
    }

    /// Removes everything TGSpeicher stores for the Telegram login on this device.
    /// This does not delete anything from the Telegram cloud itself.
    func resetAPICredentials() {
        appendDebug("LOCAL RESET requested")
        close()

        KeychainStore.delete(apiIDKey)
        KeychainStore.delete(apiHashKey)
        KeychainStore.delete("tdlib.database-key")

        let fm = FileManager.default
        if let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            try? fm.removeItem(at: support.appendingPathComponent("TGSpeicher-TDLib", isDirectory: true))
        }

        let temporary = fm.temporaryDirectory
        try? fm.removeItem(at: temporary.appendingPathComponent("TGSpeicherChunks", isDirectory: true))
        try? fm.removeItem(at: temporary.appendingPathComponent("TGSpeicherExports", isDirectory: true))

        tdlibParametersInFlight = false
        tdlibParametersConfigured = false
        accountName = "Telegram"
        savedMessagesChatID = nil
        lastError = nil
        lastAuthorizationStateName = "Reset"
        authorizationStage = .apiCredentials
        appendDebug("Local Telegram session, API credentials and database key deleted")
    }

    func retryConnection() {
        guard hasAPICredentials else {
            appendDebug("Retry requested without API credentials")
            authorizationStage = .apiCredentials
            return
        }

        appendDebug("Manual connection retry requested")
        close()
        let generation = UUID()
        startGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.startGeneration == generation else { return }
            self.start()
        }
    }

    func setPhoneNumber(_ number: String) {
        let value = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        lastError = nil
        appendDebug("Submitting phone number to TDLib")
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
                self.appendDebug("Phone number accepted by TDLib")
            }
        }
    }

    func submitCode(_ code: String) {
        lastError = nil
        appendDebug("Submitting verification code")
        send([
            "@type": "checkAuthenticationCode",
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines)
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
            } else {
                self.lastError = nil
                self.appendDebug("Verification code accepted")
            }
        }
    }

    func submitPassword(_ password: String) {
        lastError = nil
        appendDebug("Submitting 2FA password")
        send(["@type": "checkAuthenticationPassword", "password": password]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
            } else {
                self.lastError = nil
                self.appendDebug("2FA password accepted")
            }
        }
    }

    func logOut() {
        appendDebug("Telegram logout requested")
        send(["@type": "logOut"]) { [weak self] response in
            self?.surfaceError(response)
        }
    }

    func send(_ request: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
        guard let clientID else {
            DispatchQueue.main.async { self.lastError = "Telegram is not connected yet." }
            appendDebug("Cannot send request: no active TDLib client")
            return
        }

        var payload = request
        let requestType = request["@type"] as? String ?? "unknown"

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
            appendDebug("→ \(requestType)")
            td_send(clientID, json)
        } catch {
            appendDebug("JSON serialization failed for \(requestType): \(error.localizedDescription)")
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
        guard clientID == nil else {
            appendDebug("Start ignored: client already active")
            return
        }
        guard hasAPICredentials else {
            appendDebug("Start stopped: API credentials missing")
            authorizationStage = .apiCredentials
            return
        }

        authorizationStage = .connecting
        tdlibParametersInFlight = false
        tdlibParametersConfigured = false
        lastError = nil
        lastAuthorizationStateName = "Starting"

        let generation = UUID()
        startGeneration = generation

        let id = td_create_client_id()
        clientID = id
        isReceiving = true
        appendDebug("Created TDLib client \(id)")

        let logRequest: [String: Any] = ["@type": "setLogVerbosityLevel", "new_verbosity_level": 1]
        if let data = try? JSONSerialization.data(withJSONObject: logRequest),
           let json = String(data: data, encoding: .utf8) {
            _ = td_execute(json)
        }

        receiveQueue.async { [weak self] in
            self?.receiveLoop()
        }

        // IMPORTANT: td_create_client_id() only allocates an ID. The simplified TDLib JSON
        // interface does not instantiate the client or emit updates until the FIRST td_send().
        // A harmless getOption request is the same bootstrap pattern used by TDLib's own example.
        send(["@type": "getOption", "name": "version"]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.appendDebug("Bootstrap request returned an error")
                self.surfaceError(response)
            } else {
                self.appendDebug("TDLib bootstrap request completed")
            }
        }

        scheduleStartupWatchdog(clientID: id, generation: generation)
    }

    private func scheduleStartupWatchdog(clientID id: Int32, generation: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self,
                  self.clientID == id,
                  self.startGeneration == generation,
                  self.authorizationStage == .connecting else { return }

            self.appendDebug("Watchdog: still connecting after 4s, querying authorization state")
            self.send(["@type": "getAuthorizationState"]) { [weak self] response in
                guard let self else { return }
                let type = response["@type"] as? String ?? "unknown"
                self.appendDebug("Watchdog response: \(type)")
                if type.hasPrefix("authorizationState") {
                    self.handleAuthorizationState(response)
                } else if type == "error" {
                    self.surfaceError(response)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            guard let self,
                  self.clientID == id,
                  self.startGeneration == generation,
                  self.authorizationStage == .connecting else { return }

            self.appendDebug("Watchdog: connection has been stuck for 12s")
            self.lastError = "Telegram is taking unusually long to initialize. Open the Debug console to retry the connection or erase the local Telegram session."
        }
    }

    private func close() {
        guard let clientID else { return }
        appendDebug("Closing TDLib client \(clientID)")
        isReceiving = false

        if let data = try? JSONSerialization.data(withJSONObject: ["@type": "close"]),
           let json = String(data: data, encoding: .utf8) {
            td_send(clientID, json)
        }

        self.clientID = nil
        tdlibParametersInFlight = false
        tdlibParametersConfigured = false

        lock.lock()
        callbacks.removeAll()
        lock.unlock()
    }

    private func receiveLoop() {
        appendDebug("Receive loop started")
        while isReceiving {
            autoreleasepool {
                if let result = td_receive(0.5) {
                    let string = String(cString: result)
                    guard let data = string.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        appendDebug("Received malformed TDLib JSON")
                        return
                    }
                    handle(object)
                }
            }
        }
        appendDebug("Receive loop stopped")
    }

    private func handle(_ response: [String: Any]) {
        // td_receive is global for all simplified JSON clients. Ignore delayed events from an
        // older client after a retry/reset so they can never corrupt the new authorization flow.
        if let responseClient = Self.int(response["@client_id"]),
           let activeClient = clientID,
           responseClient != Int(activeClient) {
            appendDebug("Ignored delayed event from old client \(responseClient)")
            return
        }

        let type = response["@type"] as? String ?? ""
        lastActivityAt = Date()

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
        } else if type == "error", response["@extra"] == nil {
            let message = response["message"] as? String ?? "Telegram returned an unknown error."
            appendDebug("← error: \(message)")
            DispatchQueue.main.async {
                self.lastError = message
            }
        } else if type.hasPrefix("update") {
            // Keep the console useful without flooding it with full Telegram payloads.
            if type != "updateOption" {
                appendDebug("← \(type)")
            }
        }
    }

    private func handleAuthorizationState(_ state: [String: Any]) {
        let type = state["@type"] as? String ?? "unknown"
        lastAuthorizationStateName = type
        appendDebug("AUTH → \(type)")

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
                appendDebug("Login code delivery: \(codeTypeName)")
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
            appendDebug("Unhandled authorization state: \(type)")
        }
    }

    private func configureTDLib() {
        guard !tdlibParametersConfigured, !tdlibParametersInFlight else {
            appendDebug("Duplicate setTdlibParameters prevented")
            return
        }
        guard let apiIDString = KeychainStore.get(apiIDKey),
              let apiID = Int(apiIDString),
              let apiHash = KeychainStore.get(apiHashKey) else {
            appendDebug("TDLib parameters cannot be configured: credentials missing")
            publish(stage: .apiCredentials)
            return
        }

        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            appendDebug("Unable to open Application Support directory")
            lastError = "TGSpeicher could not open its local Application Support directory."
            return
        }

        let root = support.appendingPathComponent("TGSpeicher-TDLib", isDirectory: true)
        let database = root.appendingPathComponent("database", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        do {
            try fm.createDirectory(at: database, withIntermediateDirectories: true)
            try fm.createDirectory(at: files, withIntermediateDirectories: true)
        } catch {
            appendDebug("Unable to create TDLib directories: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return
        }

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
            "application_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        ]

        tdlibParametersInFlight = true
        appendDebug("Configuring TDLib parameters")
        send(params) { [weak self] response in
            guard let self else { return }
            self.tdlibParametersInFlight = false
            if response["@type"] as? String == "error" {
                self.tdlibParametersConfigured = false
                self.surfaceError(response)
            } else {
                self.tdlibParametersConfigured = true
                self.lastError = nil
                self.appendDebug("TDLib parameters accepted")
            }
        }
    }

    private func loadSelfAndSavedMessages() {
        appendDebug("Loading Telegram account profile")
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

            guard let userID = Self.int64(response["id"]) else {
                self.appendDebug("getMe returned no usable user ID")
                return
            }

            self.send(["@type": "createPrivateChat", "user_id": userID, "force": false]) { [weak self] chat in
                guard let self else { return }
                if chat["@type"] as? String == "error" {
                    self.surfaceError(chat)
                    return
                }
                self.savedMessagesChatID = Self.int64(chat["id"])
                self.appendDebug("Saved Messages chat is ready")
            }
        }
    }

    private func surfaceError(_ response: [String: Any]) {
        guard response["@type"] as? String == "error" else { return }
        let rawMessage = response["message"] as? String ?? "Telegram returned an unknown error."
        appendDebug("TDLib error: \(rawMessage)")
        let message = rawMessage.replacingOccurrences(of: "_", with: " ").localizedCapitalized
        DispatchQueue.main.async {
            self.lastError = message
        }
    }

    private func publish(stage: AuthorizationStage) {
        DispatchQueue.main.async {
            self.authorizationStage = stage
        }
    }

    private func appendDebug(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async {
            self.debugLines.append(line)
            if self.debugLines.count > 250 {
                self.debugLines.removeFirst(self.debugLines.count - 250)
            }
            self.lastActivityAt = Date()
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
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
