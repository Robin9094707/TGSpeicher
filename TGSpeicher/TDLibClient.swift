import Foundation
import Combine
import UIKit
import TDLibFramework

final class TelegramClient: ObservableObject {
    @Published private(set) var authorizationStage: AuthorizationStage = .connecting
    @Published private(set) var accountName = "Telegram"
    @Published private(set) var savedMessagesChatID: Int64?
    @Published private(set) var writableBackupChannels: [TelegramBackupDestination] = []
    @Published private(set) var maxUploadBytes: Int64 = 2_000_000_000
    @Published private(set) var loginCodeInfo: LoginCodeInfo?
    @Published private(set) var debugLines: [String] = []
    @Published private(set) var lastAuthorizationStateName = "Not started"
    @Published private(set) var lastActivityAt: Date?
    @Published private(set) var isAuthActionInFlight = false
    @Published var lastError: String?

    private let apiIDKey = "telegram.api-id"
    private let apiHashKey = "telegram.api-hash"

    private var clientID: Int32?
    private let clientLock = NSLock()
    private let callbackLock = NSLock()
    private let receiverLock = NSLock()
    private let receiveQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.tdlib.receive", qos: .userInitiated)

    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var observers: [UUID: ([String: Any]) -> Void] = [:]
    private var finalMessageCallbacks: [Int64: ([String: Any]) -> Void] = [:]
    private var earlyFinalMessages: [Int64: [String: Any]] = [:]

    private var receiverRunning = false
    private var receiverShouldStop = false
    private var tdlibParametersInFlight = false
    private var tdlibParametersConfigured = false
    private var startGeneration = UUID()

    var hasAPICredentials: Bool {
        KeychainStore.get(apiIDKey) != nil && KeychainStore.get(apiHashKey) != nil
    }

    var debugText: String { debugLines.joined(separator: "\n") }
    var clientDescription: String { activeClientID.map { "Client \($0)" } ?? "No active client" }

    private var activeClientID: Int32? {
        clientLock.lock(); defer { clientLock.unlock() }
        return clientID
    }

    init() {
        debug("TGSpeicher \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        if hasAPICredentials {
            debug("API credentials found in local Keychain")
            start()
        } else {
            authorizationStage = .apiCredentials
            debug("No API credentials stored")
        }
    }

    deinit {
        receiverLock.lock(); receiverShouldStop = true; receiverLock.unlock()
        closeClient()
    }

    // MARK: Credentials / lifecycle

    func saveAPICredentials(apiIDText: String, apiHash: String) {
        let hash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = Int(apiIDText.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 else {
            lastError = "Please enter a valid Telegram API ID."
            return
        }
        guard hash.count >= 16 else {
            lastError = "Please enter the API hash from my.telegram.org."
            return
        }
        KeychainStore.set(String(id), for: apiIDKey)
        KeychainStore.set(hash, for: apiHashKey)
        lastError = nil
        debug("Saved Telegram API credentials")
        start()
    }

    func resetAPICredentials() {
        debug("LOCAL RESET requested")
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

        accountName = "Telegram"
        savedMessagesChatID = nil
        loginCodeInfo = nil
        lastError = nil
        lastAuthorizationStateName = "Reset"
        isAuthActionInFlight = false
        authorizationStage = .apiCredentials
        debug("Local Telegram login data deleted")
    }

    func retryConnection() {
        guard hasAPICredentials else { authorizationStage = .apiCredentials; return }
        closeClient()
        let generation = UUID()
        startGeneration = generation
        debug("Manual connection retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.startGeneration == generation else { return }
            self.start()
        }
    }

    private func start() {
        guard activeClientID == nil else { return }
        guard hasAPICredentials else { authorizationStage = .apiCredentials; return }

        authorizationStage = .connecting
        loginCodeInfo = nil
        lastError = nil
        isAuthActionInFlight = false
        tdlibParametersInFlight = false
        tdlibParametersConfigured = false
        lastAuthorizationStateName = "Starting"

        let generation = UUID()
        startGeneration = generation
        let id = td_create_client_id()
        clientLock.lock(); clientID = id; clientLock.unlock()
        debug("Created TDLib client \(id)")
        startReceiverIfNeeded()

        let log: [String: Any] = ["@type": "setLogVerbosityLevel", "new_verbosity_level": 1]
        if let data = try? JSONSerialization.data(withJSONObject: log), let json = String(data: data, encoding: .utf8) {
            _ = td_execute(json)
        }

        // The simplified TDLib client becomes active only after its first td_send.
        send(["@type": "getOption", "name": "version"]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" { self.surfaceError(response) }
            else { self.debug("TDLib bootstrap completed") }
        }
        scheduleStartupWatchdog(clientID: id, generation: generation)
    }

    private func closeClient() {
        guard let id = activeClientID else { return }
        debug("Closing TDLib client \(id)")
        if let data = try? JSONSerialization.data(withJSONObject: ["@type": "close"]), let json = String(data: data, encoding: .utf8) {
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

    // MARK: Authorization

    func setPhoneNumber(_ number: String) {
        let clean = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard case .phone = authorizationStage else {
            debug("Duplicate phone-code request blocked")
            lastError = "A login-code transaction is already active. Use the current code instead of requesting another one."
            return
        }
        guard !isAuthActionInFlight else { return }

        isAuthActionInFlight = true
        lastError = nil
        debug("Submitting phone number exactly once")
        send([
            "@type": "setAuthenticationPhoneNumber",
            "phone_number": clean,
            "settings": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" { self.surfaceError(response) }
        }
    }

    func requestQRLogin() {
        guard !isAuthActionInFlight else { return }
        isAuthActionInFlight = true
        lastError = nil
        debug("Requesting QR login")
        send(["@type": "requestQrCodeAuthentication", "other_user_ids": []]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" { self.surfaceError(response) }
        }
    }

    func resendAuthenticationCode() {
        guard case .code = authorizationStage, let info = loginCodeInfo else { return }
        guard info.nextDeliveryType != nil else {
            lastError = "Telegram did not offer another delivery method. Use the newest code from Telegram."
            return
        }
        guard info.canResend else {
            lastError = "Telegram allows another code in \(info.remainingSeconds) seconds."
            return
        }
        guard !isAuthActionInFlight else { return }

        isAuthActionInFlight = true
        lastError = nil
        debug("Resending code after Telegram timeout")
        send([
            "@type": "resendAuthenticationCode",
            "reason": ["@type": "resendCodeReasonUserRequest"]
        ]) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" { self.surfaceError(response) }
        }
    }

    func submitCode(_ code: String) {
        performAuthRequest(["@type": "checkAuthenticationCode", "code": code.trimmingCharacters(in: .whitespacesAndNewlines)], label: "verification code")
    }

    func submitPassword(_ password: String) {
        performAuthRequest(["@type": "checkAuthenticationPassword", "password": password], label: "2FA password")
    }

    func submitEmailAddress(_ email: String) {
        performAuthRequest(["@type": "setAuthenticationEmailAddress", "email_address": email.trimmingCharacters(in: .whitespacesAndNewlines)], label: "email address")
    }

    func submitEmailCode(_ code: String) {
        performAuthRequest([
            "@type": "checkAuthenticationEmailCode",
            "code": ["@type": "emailAddressAuthenticationCode", "code": code.trimmingCharacters(in: .whitespacesAndNewlines)]
        ], label: "email code")
    }

    private func performAuthRequest(_ request: [String: Any], label: String) {
        guard !isAuthActionInFlight else { return }
        isAuthActionInFlight = true
        lastError = nil
        debug("Submitting \(label)")
        send(request) { [weak self] response in
            guard let self else { return }
            self.isAuthActionInFlight = false
            if response["@type"] as? String == "error" { self.surfaceError(response) }
        }
    }

    func logOut() {
        send(["@type": "logOut"]) { [weak self] response in
            if response["@type"] as? String == "error" { self?.surfaceError(response) }
        }
    }

    // MARK: Requests / final message IDs

    func send(_ request: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
        guard let id = activeClientID else {
            DispatchQueue.main.async { self.lastError = "Telegram is not connected yet." }
            return
        }

        var payload = request
        let type = request["@type"] as? String ?? "unknown"
        if let completion {
            let token = UUID().uuidString
            payload["@extra"] = token
            callbackLock.lock(); callbacks[token] = completion; callbackLock.unlock()
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let json = String(data: data, encoding: .utf8) else { return }
            debug("→ \(type)")
            td_send(id, json)
        } catch {
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }
    }

    func sendMessageAwaitingFinal(_ request: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        send(request) { [weak self] message in
            guard let self else { return }
            if message["@type"] as? String == "error" { completion(message); return }
            guard let temporaryID = Self.int64(message["id"]) else {
                completion(["@type": "error", "message": "Telegram returned no message ID."])
                return
            }
            if message["sending_state"] == nil || message["sending_state"] is NSNull {
                completion(message)
                return
            }

            self.callbackLock.lock()
            if let early = self.earlyFinalMessages.removeValue(forKey: temporaryID) {
                self.callbackLock.unlock()
                completion(early)
            } else {
                self.finalMessageCallbacks[temporaryID] = completion
                self.callbackLock.unlock()
                self.debug("Waiting for server-confirmed ID of temporary message \(temporaryID)")
            }
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

    /// Loads channels in which the signed-in user can publish. The result is intentionally
    /// bounded; a manual refresh is cheap and avoids keeping thousands of chats in memory.
    func refreshWritableBackupChannels() {
        send([
            "@type": "getChats",
            "chat_list": ["@type": "chatListMain"],
            "limit": 200
        ]) { [weak self] response in
            guard let self else { return }
            let ids = (response["chat_ids"] as? [Any] ?? []).compactMap { Self.int64($0) }
            self.loadWritableChannel(ids: ids, position: 0, collected: [])
        }
    }

    private func loadWritableChannel(
        ids: [Int64],
        position: Int,
        collected: [TelegramBackupDestination]
    ) {
        guard position < ids.count else {
            writableBackupChannels = collected.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return
        }
        let chatID = ids[position]
        send(["@type": "getChat", "chat_id": chatID]) { [weak self] chat in
            guard let self else { return }
            guard let type = chat["type"] as? [String: Any],
                  type["@type"] as? String == "chatTypeSupergroup",
                  let supergroupID = Self.int64(type["supergroup_id"]) else {
                self.loadWritableChannel(ids: ids, position: position + 1, collected: collected)
                return
            }
            self.send(["@type": "getSupergroup", "supergroup_id": supergroupID]) { [weak self] group in
                guard let self else { return }
                let isChannel = group["is_channel"] as? Bool ?? false
                let status = group["status"] as? [String: Any]
                let statusType = status?["@type"] as? String ?? ""
                let rights = status?["rights"] as? [String: Any]
                let canPost = statusType == "chatMemberStatusCreator" ||
                    (statusType == "chatMemberStatusAdministrator" && (rights?["can_post_messages"] as? Bool ?? false))
                var next = collected
                if isChannel && canPost {
                    next.append(TelegramBackupDestination(
                        id: chatID,
                        title: chat["title"] as? String ?? "Telegram Channel",
                        isSavedMessages: false
                    ))
                }
                self.loadWritableChannel(ids: ids, position: position + 1, collected: next)
            }
        }
    }

    private func loadUploadLimit() {
        send(["@type": "getOption", "name": "max_file_size"]) { [weak self] response in
            guard let self,
                  response["@type"] as? String == "optionValueInteger",
                  let value = Self.int64(response["value"]), value > 0 else { return }
            self.maxUploadBytes = value
        }
    }

    static func retryAfterSeconds(_ response: [String: Any]) -> Int? {
        guard response["@type"] as? String == "error" else { return nil }
        if let code = int(response["code"]), code != 429 { return nil }
        let message = response["message"] as? String ?? ""
        if let range = message.range(of: #"\d+"#, options: .regularExpression) { return Int(message[range]) }
        return 30
    }

    // MARK: Single lifetime receiver

    private func startReceiverIfNeeded() {
        receiverLock.lock()
        if receiverRunning { receiverLock.unlock(); return }
        receiverRunning = true
        receiverShouldStop = false
        receiverLock.unlock()
        receiveQueue.async { [weak self] in self?.receiveLoop() }
    }

    private func receiveLoop() {
        debug("Single lifetime TDLib receive pump started")
        while true {
            receiverLock.lock(); let stop = receiverShouldStop; receiverLock.unlock()
            if stop { break }

            autoreleasepool {
                if let result = td_receive(0.5) {
                    let string = String(cString: result)
                    if let data = string.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        handle(object)
                    } else {
                        debug("Malformed TDLib JSON ignored")
                    }
                }
            }
        }
        receiverLock.lock(); receiverRunning = false; receiverLock.unlock()
        debug("TDLib receive pump stopped")
    }

    private func handle(_ response: [String: Any]) {
        if let responseClient = Self.int(response["@client_id"]),
           let active = activeClientID,
           responseClient != Int(active) { return }

        let type = response["@type"] as? String ?? ""
        DispatchQueue.main.async { self.lastActivityAt = Date() }

        if let token = response["@extra"] as? String {
            callbackLock.lock(); let callback = callbacks.removeValue(forKey: token); callbackLock.unlock()
            if let callback { DispatchQueue.main.async { callback(response) } }
        }

        callbackLock.lock(); let currentObservers = Array(observers.values); callbackLock.unlock()
        if !currentObservers.isEmpty { DispatchQueue.main.async { currentObservers.forEach { $0(response) } } }

        switch type {
        case "updateAuthorizationState":
            if let state = response["authorization_state"] as? [String: Any] { handleAuthorizationState(state) }

        case "updateMessageSendSucceeded":
            if let oldID = Self.int64(response["old_message_id"]), let message = response["message"] as? [String: Any] {
                resolveFinalMessage(oldID: oldID, result: message)
            }

        case "updateMessageSendFailed":
            if let oldID = Self.int64(response["old_message_id"]) {
                let error = response["error"] as? [String: Any] ?? ["@type": "error", "message": "Telegram failed to send the message."]
                resolveFinalMessage(oldID: oldID, result: error)
            }

        case "error":
            if response["@extra"] == nil {
                let message = response["message"] as? String ?? "Unknown Telegram error"
                debug("← error: \(message)")
                DispatchQueue.main.async { self.lastError = message }
            }

        default:
            if type.hasPrefix("update") && type != "updateOption" && type != "updateFile" { debug("← \(type)") }
        }
    }

    private func resolveFinalMessage(oldID: Int64, result: [String: Any]) {
        callbackLock.lock()
        if let callback = finalMessageCallbacks.removeValue(forKey: oldID) {
            callbackLock.unlock()
            DispatchQueue.main.async { callback(result) }
        } else {
            earlyFinalMessages[oldID] = result
            if earlyFinalMessages.count > 50, let first = earlyFinalMessages.keys.first { earlyFinalMessages.removeValue(forKey: first) }
            callbackLock.unlock()
        }
    }

    // MARK: Authorization state machine

    private func handleAuthorizationState(_ state: [String: Any]) {
        let type = state["@type"] as? String ?? "unknown"
        debug("AUTH → \(type)")
        DispatchQueue.main.async {
            self.lastAuthorizationStateName = type
            self.isAuthActionInFlight = false
        }

        switch type {
        case "authorizationStateWaitTdlibParameters":
            configureTDLib()

        case "authorizationStateWaitPhoneNumber":
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
            DispatchQueue.main.async { self.lastError = nil; self.authorizationStage = .qr(link: link) }

        case "authorizationStateWaitEmailAddress":
            DispatchQueue.main.async { self.authorizationStage = .emailAddress(pattern: "") }

        case "authorizationStateWaitEmailCode":
            let info = state["code_info"] as? [String: Any]
            let pattern = info?["email_address_pattern"] as? String ?? "your email"
            DispatchQueue.main.async { self.authorizationStage = .emailCode(pattern: pattern) }

        case "authorizationStateWaitPassword":
            let hint = state["password_hint"] as? String ?? ""
            DispatchQueue.main.async { self.lastError = nil; self.authorizationStage = .password(hint: hint) }

        case "authorizationStateReady":
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
            tdlibParametersConfigured = false
            DispatchQueue.main.async { self.authorizationStage = .closed }

        default:
            debug("Unhandled auth state \(type)")
        }
    }

    private func parseCodeInfo(_ object: [String: Any]?) -> LoginCodeInfo? {
        guard let object else { return nil }
        let type = (object["type"] as? [String: Any])?["@type"] as? String ?? "unknown"
        let next = (object["next_type"] as? [String: Any])?["@type"] as? String
        let timeout = Self.int(object["timeout"]) ?? 0
        debug("Code delivery \(type), next=\(next ?? "none"), timeout=\(timeout)s")
        return LoginCodeInfo(
            deliveryType: type,
            deliveryDescription: Self.describeCodeType(type),
            nextDeliveryType: next,
            nextDeliveryDescription: next.map(Self.describeCodeType),
            timeout: timeout,
            resendAvailableAt: next == nil ? nil : Date().addingTimeInterval(TimeInterval(max(0, timeout)))
        )
    }

    private static func describeCodeType(_ type: String) -> String {
        if type.contains("TelegramMessage") { return "Telegram sent the code to the verified Telegram service chat in an already signed-in Telegram app." }
        if type.contains("SmsPhrase") { return "Telegram sent an SMS phrase." }
        if type.contains("SmsWord") { return "Telegram sent an SMS word." }
        if type.contains("Sms") { return "Telegram sent the code by SMS." }
        if type.contains("MissedCall") { return "Telegram selected missed-call verification." }
        if type.contains("FlashCall") { return "Telegram selected flash-call verification." }
        if type.contains("Call") { return "Telegram will provide the code by phone call." }
        if type.contains("Fragment") { return "Telegram sent the code through Fragment." }
        if type.contains("Firebase") { return "Telegram is performing device verification before code delivery." }
        return "Telegram selected a code delivery method for this account."
    }

    private func configureTDLib() {
        guard !tdlibParametersConfigured, !tdlibParametersInFlight else { return }
        guard let idText = KeychainStore.get(apiIDKey), let apiID = Int(idText), let apiHash = KeychainStore.get(apiHashKey) else {
            DispatchQueue.main.async { self.authorizationStage = .apiCredentials }
            return
        }

        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            DispatchQueue.main.async { self.lastError = "TGSpeicher cannot open Application Support." }
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

        tdlibParametersInFlight = true
        send([
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
        ]) { [weak self] response in
            guard let self else { return }
            self.tdlibParametersInFlight = false
            if response["@type"] as? String == "error" {
                self.tdlibParametersConfigured = false
                self.surfaceError(response)
            } else {
                self.tdlibParametersConfigured = true
                self.debug("TDLib parameters accepted")
            }
        }
    }

    private func scheduleStartupWatchdog(clientID id: Int32, generation: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.activeClientID == id, self.startGeneration == generation, self.authorizationStage == .connecting else { return }
            self.debug("Startup watchdog querying authorization state")
            self.send(["@type": "getAuthorizationState"]) { [weak self] response in
                guard let self else { return }
                let type = response["@type"] as? String ?? ""
                if type.hasPrefix("authorizationState") { self.handleAuthorizationState(response) }
                else if type == "error" { self.surfaceError(response) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.activeClientID == id, self.startGeneration == generation, self.authorizationStage == .connecting else { return }
            self.lastError = "Telegram is still initializing. Open Debug to retry or erase the local session."
        }
    }

    private func loadSelfAndSavedMessages() {
        loadUploadLimit()
        refreshWritableBackupChannels()
        send(["@type": "getMe"]) { [weak self] me in
            guard let self else { return }
            if me["@type"] as? String == "error" { self.surfaceError(me); return }
            let first = me["first_name"] as? String ?? ""
            let last = me["last_name"] as? String ?? ""
            self.accountName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            guard let userID = Self.int64(me["id"]) else { return }
            self.send(["@type": "createPrivateChat", "user_id": userID, "force": false]) { [weak self] chat in
                guard let self else { return }
                if chat["@type"] as? String == "error" { self.surfaceError(chat); return }
                self.savedMessagesChatID = Self.int64(chat["id"])
                self.debug("Saved Messages ready")
            }
        }
    }

    private func surfaceError(_ response: [String: Any]) {
        guard response["@type"] as? String == "error" else { return }
        let raw = response["message"] as? String ?? "Unknown Telegram error"
        debug("TDLib error: \(raw)")
        let friendly = Self.retryAfterSeconds(response).map { "Telegram rate limit: please wait about \($0) seconds." }
            ?? raw.replacingOccurrences(of: "_", with: " ")
        DispatchQueue.main.async { self.lastError = friendly }
    }

    private func debug(_ message: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async {
            self.debugLines.append(line)
            if self.debugLines.count > 300 { self.debugLines.removeFirst(self.debugLines.count - 300) }
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
