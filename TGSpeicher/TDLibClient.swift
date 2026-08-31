import Foundation
import Combine
import UIKit
import TDLibFramework

final class TelegramClient: ObservableObject {
    @Published private(set) var authorizationStage: AuthorizationStage = .connecting
    @Published private(set) var accountName: String = "Telegram"
    @Published private(set) var savedMessagesChatID: Int64?
    @Published private(set) var loginCodeInfo: LoginCodeInfo?
    @Published private(set) var debugLines: [String] = []
    @Published private(set) var lastAuthorizationStateName: String = "Not started"
    @Published private(set) var lastActivityAt: Date?
    @Published private(set) var isAuthActionInFlight = false
    @Published var lastError: String?

    private var clientID: Int32?
    private let clientLock = NSLock()

    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var observers: [UUID: ([String: Any]) -> Void] = [:]
    private var finalMessageCallbacks: [Int64: ([String: Any]) -> Void] = [:]
    private var earlyFinalMessages: [Int64: [String: Any]] = [:]
    private let callbackLock = NSLock()

    private let receiveQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.tdlib.receive", qos: .userInitiated)
    private let receiverLock = NSLock()
    private var receiverRunning = false
    private var receiverShouldStop = false

    private var tdlibParametersInFlight = false
    private var tdlibParametersConfigured = false
    private var startGeneration = UUID()

    private let apiIDKey = "telegram.api-id"
    private let apiHashKey = "telegram.api-hash"

    var hasAPICredentials: Bool {
        KeychainStore.get(apiIDKey) != nil && KeychainStore.get(apiHashKey) != nil
    }

    var debugText: String { debugLines.joined(separator: "\n") }

    var clientDescription: String {
        guard let id = activeClientID else { return "No active client" }
        return "Client \(id)"
    }

    private var activeClientID: Int32? {
        clientLock.lock(); defer { clientLock.unlock() }
        return clientID
    }

    init() {
        appendDebug("TGSpeicher \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        if hasAPICredentials {
            appendDebug("API credentials found in local Keychain")
            start()
        } else {
            authorizationStage = .apiCredentials
            appendDebug("No API credentials stored")
        }
    }

    deinit {
        receiverLock.lock()
        receiverShouldStop = true
        receiverLock.unlock()
        closeClient()
    }

    func saveAPICredentials(apiIDText: String, apiHash: String) {
        let cleanHash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiID = Int(apiIDText.trimmingCharacters(in: .whitespacesAndNewlines)), apiID > 0 else {
            lastError = "Please enter a valid Telegram API ID."
            return
        }
        guard cleanHash.count >= 16 else {
            lastError = "Please enter your Telegram API hash from my.telegram.org."
            return
        }

        KeychainStore.set(String(apiID), for: apiIDKey)
        KeychainStore.set(cleanHash, for: apiHashKey)
        appendDebug("Saved API credentials to this-device-only Keychain")
        lastError = nil
        start()
    }

    func resetAPICredentials() {
        appendDebug("LOCAL RESET requested")
        closeClient()
        KeychainStore.delete(apiIDKey)
        KeychainStore.delete(apiHashKey)
        KeychainStore.delete("tdlib.database-key")

        let fm = FileManager.default
        if let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? fm.removeItem(at: support.appendingPathComponent("TGSpeicher-TDLib", isDirectory: true))
        }
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("TGSpeicherChunks", isDirectory: true))
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("TGSpeicherExports", isDirectory: true))

        tdlibParametersInFlight = false
        tdlibParametersConfigured = false
        loginCodeInfo = nil
        accountName = "Telegram"
        savedMessagesChatID = nil
        lastError = nil
        lastAuthorizationStateName = "Reset"
        isAuthActionInFlight = false
        authorizationStage = .apiCredentials
        appendDebug("Local Telegram credentials and TDLib database deleted")
    }

    func retryConnection() {
        guard hasAPICredentials else {
            authorizationStage = .apiCredentials
            return
        }
        appendDebug("Manual connection retry")
        closeClient()
        let generation = UUID()
        startGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.startGeneration == generation else { return }
            self.start()
        }
    }

    func setPhoneNumber(_ number: String) {
        let clean = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard case .phone = authorizationStage else {
            appendDebug("Duplicate phone-code request blocked because auth already advanced")
            lastError = "A Telegram login transaction is already active. Use the current code screen instead of requesting another code."
            return
        }
        guard !isAuthActionInFlight else {
            appendDebug("Duplicate phone-code tap ignored")
            return
        }

        isAuthActionInFlight = true
        lastError = nil
        appendDebug("Submitting phone number once")
        send([
            "@type": "setAuthenticationPhoneNumber",
            "phone_number": clean,
            "settings": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
            } else {
                self.appendDebug("Phone number accepted; waiting for authorization update")
            }
        }
    }

    func requestQRLogin() {
        guard !isAuthActionInFlight else { return }
        isAuthActionInFlight = true
        lastError = nil
        appendDebug("Requesting Telegram QR login")
        send([
            "@type": "requestQrCodeAuthentication",
            "other_user_ids": []
        ]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
            }
        }
    }

    func resendAuthenticationCode() {
        guard case .code = authorizationStage, let info = loginCodeInfo else { return }
        guard info.nextDeliveryType != nil else {
            lastError = "Telegram did not offer another delivery method for this login. Use the newest code from Telegram."
            return
        }
        guard info.canResend else {
            lastError = "Telegram allows another code in \(info.remainingSeconds) seconds."
            return
        }
        guard !isAuthActionInFlight else { return }

        isAuthActionInFlight = true
        lastError = nil
        appendDebug("Resending authentication code after server timeout")
        send([
            "@type": "resendAuthenticationCode",
            "reason": ["@type": "resendCodeReasonUserRequest"]
        ]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" {
                self.surfaceError(response)
            }
        }
    }

    func submitCode(_ code: String) {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isAuthActionInFlight else { return }
        isAuthActionInFlight = true
        lastError = nil
        appendDebug("Submitting verification code")
        send(["@type": "checkAuthenticationCode", "code": clean]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" { self.surfaceError(response) }
        }
    }

    func submitPassword(_ password: String) {
        guard !password.isEmpty, !isAuthActionInFlight else { return }
        isAuthActionInFlight = true
        lastError = nil
        appendDebug("Submitting 2FA password")
        send(["@type": "checkAuthenticationPassword", "password": password]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" { self.surfaceError(response) }
        }
    }

    func submitEmailAddress(_ email: String) {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.contains("@"), !isAuthActionInFlight else { return }
        isAuthActionInFlight = true
        lastError = nil
        send(["@type": "setAuthenticationEmailAddress", "email_address": clean]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" { self.surfaceError(response) }
        }
    }

    func submitEmailCode(_ code: String) {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isAuthActionInFlight else { return }
        isAuthActionInFlight = true
        lastError = nil
        send([
            "@type": "checkAuthenticationEmailCode",
            "code": ["@type": "emailAddressAuthenticationCode", "code": clean]
        ]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" { self.surfaceError(response) }
        }
    }

    func logOut() {
        send(["@type": "logOut"]) { [weak self] response in self?.surfaceError(response) }
    }

    func send(_ request: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
        guard let id = activeClientID else {
            DispatchQueue.main.async { self.lastError = "Telegram is not connected yet." }
            return
        }

        var payload = request
        let requestType = request["@type"] as? String ?? "unknown"
        if let completion {
            let token = UUID().uuidString
            payload["@extra"] = token
            callbackLock.lock()
            callbacks[token] = completion
            callbackLock.unlock()
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let json = String(data: data, encoding: .utf8) else { return }
            appendDebug("→ \(requestType)")
            td_send(id, json)
        } catch {
            appendDebug("JSON error for \(requestType): \(error.localizedDescription)")
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }
    }

    /// sendMessage initially returns a temporary message while TDLib uploads the file.
    /// This helper waits for updateMessageSendSucceeded/updateMessageSendFailed and therefore
    /// always returns the final server-side message ID and final Telegram file object.
    func sendMessageAwaitingFinal(_ request: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        send(request) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                completion(response)
                return
            }
            guard let temporaryID = Self.int64(response["id"]) else {
                completion(["@type": "error", "message": "Telegram returned a message without an ID."])
                return
            }

            if response["sending_state"] == nil || response["sending_state"] is NSNull {
                completion(response)
                return
            }

            self.callbackLock.lock()
            if let early = self.earlyFinalMessages.removeValue(forKey: temporaryID) {
                self.callbackLock.unlock()
                completion(early)
                return
            }
            self.finalMessageCallbacks[temporaryID] = completion
            self.callbackLock.unlock()
            self.appendDebug("Waiting for final message ID for temporary \(temporaryID)")
        }
    }

    @discardableResult
    func addUpdateObserver(_ observer: @escaping ([String: Any]) -> Void) -> UUID {
        let id = UUID()
        callbackLock.lock(); observers[id] = observer; callbackLock.unlock()
        return id
    }

    func removeUpdateObserver(_ id: UUID) {
        callbackLock.lock(); observers.removeValue(forKey: id); callbackLock.unlock()
    }

    func clearError() { lastError = nil }

    static func retryAfterSeconds(_ response: [String: Any]) -> Int? {
        guard response["@type"] as? String == "error" else { return nil }
        if let code = Self.int(response["code"]), code != 429 { return nil }
        let message = response["message"] as? String ?? ""
        if let range = message.range(of: #"\d+"#, options: .regularExpression) {
            return Int(message[range])
        }
        return 30
    }

    private func start() {
        guard activeClientID == nil else { return }
        guard hasAPICredentials else {
            authorizationStage = .apiCredentials
            return
        }

        authorizationStage = .connecting
        tdlibParametersInFlight = false
        tdlibParametersConfigured = false
        loginCodeInfo = nil
        lastError = nil
        lastAuthorizationStateName = "Starting"
        isAuthActionInFlight = false

        let generation = UUID()
        startGeneration = generation
        let id = td_create_client_id()
        clientLock.lock(); clientID = id; clientLock.unlock()
        appendDebug("Created TDLib client \(id)")

        startReceiverIfNeeded()

        let logRequest: [String: Any] = ["@type": "setLogVerbosityLevel", "new_verbosity_level": 1]
        if let data = try? JSONSerialization.data(withJSONObject: logRequest), let json = String(data: data, encoding: .utf8) {
            _ = td_execute(json)
        }

        // td_create_client_id() only allocates an ID. This harmless first request actually starts
        // the simplified JSON client and lets updateAuthorizationState begin flowing.
        send(["@type": "getOption", "name": "version"]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" { self.surfaceError(response) }
            else { self.appendDebug("TDLib bootstrap completed") }
        }
        scheduleStartupWatchdog(clientID: id, generation: generation)
    }

    private func startReceiverIfNeeded() {
        receiverLock.lock()
        if receiverRunning {
            receiverLock.unlock()
            return
        }
        receiverRunning = true
        receiverShouldStop = false
        receiverLock.unlock()

        receiveQueue.async { [weak self] in self?.receiveLoop() }
    }

    private func receiveLoop() {
        appendDebug("Single lifetime TDLib receive pump started")
        while true {
            receiverLock.lock(); let shouldStop = receiverShouldStop; receiverLock.unlock()
            if shouldStop { break }

            autoreleasepool {
                guard let result = td_receive(0.5) else { return }
                let string = String(cString: result)
                guard let data = string.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    appendDebug("Malformed TDLib JSON ignored")
                    return
                }
                handle(object)
            }
        }
        receiverLock.lock(); receiverRunning = false; receiverLock.unlock()
        appendDebug("TDLib receive pump stopped")
    }

    private func scheduleStartupWatchdog(clientID id: Int32, generation: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.activeClientID == id, self.startGeneration == generation,
                  self.authorizationStage == .connecting else { return }
            self.appendDebug("Watchdog: querying authorization state after 5s")
            self.send(["@type": "getAuthorizationState"]) { [weak self] response in
                guard let self else { return }
                if (response["@type"] as? String ?? "").hasPrefix("authorizationState") {
                    self.handleAuthorizationState(response)
                } else if response["@type"] as? String == "error" {
                    self.surfaceError(response)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self, self.activeClientID == id, self.startGeneration == generation,
                  self.authorizationStage == .connecting else { return }
            self.appendDebug("Startup watchdog reached 15 seconds")
            self.lastError = "Telegram is still initializing. Open Debug to retry or erase the local session."
        }
    }

    private func closeClient() {
        guard let id = activeClientID else { return }
        appendDebug("Closing TDLib client \(id)")
        if let data = try? JSONSerialization.data(withJSONObject: ["@type": "close"]),
           let json = String(data: data, encoding: .utf8) {
            td_send(id, json)
        }
        clientLock.lock(); clientID = nil; clientLock.unlock()
        tdlibParametersInFlight = false
        tdlibParametersConfigured = false
        loginCodeInfo = nil

        callbackLock.lock()
        callbacks.removeAll()
        finalMessageCallbacks.removeAll()
        earlyFinalMessages.removeAll()
        callbackLock.unlock()
    }

    private func handle(_ response: [String: Any]) {
        if let responseClient = Self.int(response["@client_id"]),
           let active = activeClientID,
           responseClient != Int(active) {
            return
        }

        let type = response["@type"] as? String ?? ""
        DispatchQueue.main.async { self.lastActivityAt = Date() }

        if let token = response["@extra"] as? String {
            callbackLock.lock(); let callback = callbacks.removeValue(forKey: token); callbackLock.unlock()
            if let callback { DispatchQueue.main.async { callback(response) } }
        }

        callbackLock.lock(); let currentObservers = Array(observers.values); callbackLock.unlock()
        if !currentObservers.isEmpty {
            DispatchQueue.main.async { currentObservers.forEach { $0(response) } }
        }

        switch type {
        case "updateAuthorizationState":
            if let state = response["authorization_state"] as? [String: Any] { handleAuthorizationState(state) }

        case "updateMessageSendSucceeded":
            guard let oldID = Self.int64(response["old_message_id"]),
                  let message = response["message"] as? [String: Any] else { return }
            resolveFinalMessage(oldID: oldID, result: message)

        case "updateMessageSendFailed":
            guard let oldID = Self.int64(response["old_message_id"]) else { return }
            let error = response["error"] as? [String: Any]
                ?? ["@type": "error", "message": "Telegram failed to send the message."]
            resolveFinalMessage(oldID: oldID, result: error)

        case "error":
            if response["@extra"] == nil {
                let message = response["message"] as? String ?? "Telegram returned an unknown error."
                appendDebug("← error: \(message)")
                DispatchQueue.main.async { self.lastError = message }
            }

        default:
            if type.hasPrefix("update") && type != "updateOption" && type != "updateFile" {
                appendDebug("← \(type)")
            }
        }
    }

    private func resolveFinalMessage(oldID: Int64, result: [String: Any]) {
        callbackLock.lock()
        if let callback = finalMessageCallbacks.removeValue(forKey: oldID) {
            callbackLock.unlock()
            appendDebug("Final send result received for temporary \(oldID)")
            DispatchQueue.main.async { callback(result) }
        } else {
            earlyFinalMessages[oldID] = result
            if earlyFinalMessages.count > 50 { earlyFinalMessages.removeValue(forKey: earlyFinalMessages.keys.first!) }
            callbackLock.unlock()
        }
    }

    private func handleAuthorizationState(_ state: [String: Any]) {
        let type = state["@type"] as? String ?? "unknown"
        DispatchQueue.main.async {
            self.lastAuthorizationStateName = type
            self.isAuthActionInFlight = false
        }
        appendDebug("AUTH → \(type)")

        switch type {
        case "authorizationStateWaitTdlibParameters":
            configureTDLib()

        case "authorizationStateWaitPhoneNumber":
            tdlibParametersInFlight = false
            tdlibParametersConfigured = true
            DispatchQueue.main.async {
                self.loginCodeInfo = nil
                self.lastError = nil
                self.authorizationStage = .phone
            }

        case "authorizationStateWaitCode":
            let info = parseCodeInfo(state["code_info"] as? [String: Any])
            DispatchQueue.main.async {
                self.loginCodeInfo = info
                self.lastError = nil
                self.authorizationStage = .code(hint: info?.deliveryDescription ?? "Enter the code Telegram sent to you.")
            }

        case "authorizationStateWaitOtherDeviceConfirmation":
            let link = state["link"] as? String ?? ""
            DispatchQueue.main.async {
                self.lastError = nil
                self.authorizationStage = .qr(link: link)
            }

        case "authorizationStateWaitEmailAddress":
            DispatchQueue.main.async { self.authorizationStage = .emailAddress(pattern: "") }

        case "authorizationStateWaitEmailCode":
            let codeInfo = state["code_info"] as? [String: Any]
            let pattern = codeInfo?["email_address_pattern"] as? String ?? "your email address"
            DispatchQueue.main.async { self.authorizationStage = .emailCode(pattern: pattern) }

        case "authorizationStateWaitPassword":
            let hint = state["password_hint"] as? String ?? ""
            DispatchQueue.main.async {
                self.lastError = nil
                self.authorizationStage = .password(hint: hint)
            }

        case "authorizationStateReady":
            tdlibParametersInFlight = false
            tdlibParametersConfigured = true
            DispatchQueue.main.async {
                self.loginCodeInfo = nil
                self.lastError = nil
                self.authorizationStage = .ready
            }
            loadSelfAndSavedMessages()

        case "authorizationStateClosing", "authorizationStateLoggingOut":
            DispatchQueue.main.async { self.authorizationStage = .connecting }

        case "authorizationStateClosed":
            tdlibParametersInFlight = false
            tdlibParametersConfigured = false
            DispatchQueue.main.async { self.authorizationStage = .closed }

        default:
            appendDebug("Unhandled authorization state: \(type)")
        }
    }

    private func parseCodeInfo(_ object: [String: Any]?) -> LoginCodeInfo? {
        guard let object else { return nil }
        let typeName = (object["type"] as? [String: Any])?["@type"] as? String ?? "unknown"
        let nextName = (object["next_type"] as? [String: Any])?["@type"] as? String
        let timeout = Self.int(object["timeout"]) ?? 0
        let description = Self.describeCodeType(typeName)
        let nextDescription = nextName.map(Self.describeCodeType)
        appendDebug("Code delivery \(typeName), next=\(nextName ?? "none"), timeout=\(timeout)s")
        return LoginCodeInfo(
            deliveryType: typeName,
            deliveryDescription: description,
            nextDeliveryType: nextName,
            nextDeliveryDescription: nextDescription,
            timeout: timeout,
            resendAvailableAt: nextName == nil ? nil : Date().addingTimeInterval(TimeInterval(max(0, timeout)))
        )
    }

    private static func describeCodeType(_ type: String) -> String {
        if type.contains("TelegramMessage") { return "Telegram sent the code to the verified Telegram service chat in an already signed-in Telegram app." }
        if type.contains("SmsPhrase") { return "Telegram sent an SMS containing a phrase. Enter the requested phrase." }
        if type.contains("SmsWord") { return "Telegram sent an SMS containing a word. Enter the requested word." }
        if type.contains("Sms") { return "Telegram sent the login code by SMS." }
        if type.contains("MissedCall") { return "Telegram will use a missed call to verify this login." }
        if type.contains("FlashCall") { return "Telegram will verify this login with a flash call." }
        if type.contains("Call") { return "Telegram will provide the code by phone call." }
        if type.contains("Fragment") { return "Telegram sent the code through Fragment." }
        if type.contains("Firebase") { return "Telegram is using device verification before delivering the code." }
        return "Telegram selected a login-code delivery method for this account."
    }

    private func configureTDLib() {
        guard !tdlibParametersConfigured, !tdlibParametersInFlight else { return }
        guard let apiIDString = KeychainStore.get(apiIDKey), let apiID = Int(apiIDString),
              let apiHash = KeychainStore.get(apiHashKey) else {
            DispatchQueue.main.async { self.authorizationStage = .apiCredentials }
            return
        }

        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            DispatchQueue.main.async { self.lastError = "TGSpeicher could not open Application Support." }
            return
        }
        let root = support.appendingPathComponent("TGSpeicher-TDLib", isDirectory: true)
        let database = root.appendingPathComponent("database", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        do {
            try fm.createDirectory(at: database, withIntermediateDirectories: true)
            try fm.createDirectory(at: files, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
            return
        }

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
            "system_language_code": Locale.current.language.languageCode?.identifier ?? "en",
            "device_model": UIDevice.current.model,
            "system_version": UIDevice.current.systemVersion,
            "application_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
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
                self.appendDebug("TDLib parameters accepted")
            }
        }
    }

    private func loadSelfAndSavedMessages() {
        send(["@type": "getMe"]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" { self.surfaceError(response); return }
            let first = response["first_name"] as? String ?? ""
            let last = response["last_name"] as? String ?? ""
            let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            self.accountName = name.isEmpty ? "Telegram" : name
            guard let userID = Self.int64(response["id"]) else { return }

            self.send(["@type": "createPrivateChat", "user_id": userID, "force": false]) { [weak self] chat in
                guard let self else { return }
                if chat["@type"] as? String == "error" { self.surfaceError(chat); return }
                self.savedMessagesChatID = Self.int64(chat["id"])
                self.appendDebug("Saved Messages chat ready: \(self.savedMessagesChatID ?? 0)")
            }
        }
    }

    private func surfaceError(_ response: [String: Any]) {
        guard response["@type"] as? String == "error" else { return }
        let raw = response["message"] as? String ?? "Telegram returned an unknown error."
        appendDebug("TDLib error: \(raw)")
        let friendly: String
        if let wait = Self.retryAfterSeconds(response) {
            friendly = "Telegram rate limit: please wait about \(wait) seconds before trying again."
        } else {
            friendly = raw.replacingOccurrences(of: "_", with: " ")
        }
        DispatchQueue.main.async { self.lastError = friendly }
    }

    private func appendDebug(_ message: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async {
            self.debugLines.append(line)
            if self.debugLines.count > 300 { self.debugLines.removeFirst(self.debugLines.count - 300) }
            self.lastActivityAt = Date()
        }
    }

    static func int64(_ value: Any?) -> Int64? {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? NSNumber { return v.int64Value }
        if let v = value as? String { return Int64(v) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Int32 { return Int(v) }
        if let v = value as? NSNumber { return v.intValue }
        if let v = value as? String { return Int(v) }
        return nil
    }
}
