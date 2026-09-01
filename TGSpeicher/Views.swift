import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct RootView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore

    var body: some View {
        ZStack {
            AppBackground()
            switch telegram.authorizationStage {
            case .ready:
                MainCloudView(telegram: telegram, cloud: cloud)
            default:
                LoginView(telegram: telegram)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            EmergencyDebugOverlay(telegram: telegram)
                .padding(18)
        }
        .alert("Telegram", isPresented: Binding(
            get: { telegram.lastError != nil },
            set: { if !$0 { telegram.clearError() } }
        )) {
            Button("OK", role: .cancel) { telegram.clearError() }
        } message: {
            Text(telegram.lastError ?? "")
        }
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            RadialGradient(
                colors: [.blue.opacity(0.17), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 540
            )
            LinearGradient(
                colors: [.clear, Color(uiColor: .secondarySystemBackground).opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Login

struct LoginView: View {
    @ObservedObject var telegram: TelegramClient
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var phone = "+49"
    @State private var code = ""
    @State private var password = ""
    @State private var email = ""
    @State private var emailCode = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 26)
                hero
                Group {
                    switch telegram.authorizationStage {
                    case .apiCredentials: credentialsCard
                    case .connecting: connectingCard
                    case .phone: phoneCard
                    case .code(let hint): codeCard(hint: hint)
                    case .password(let hint): passwordCard(hint: hint)
                    case .qr(let link): qrCard(link: link)
                    case .emailAddress: emailAddressCard
                    case .emailCode(let pattern): emailCodeCard(pattern: pattern)
                    case .closed:
                        recoveryCard(title: "Session closed", message: "Telegram closed the local session. Retry without deleting your cloud files.")
                    case .error(let text):
                        recoveryCard(title: "Telegram needs attention", message: text)
                    case .ready: EmptyView()
                    }
                }
                .frame(maxWidth: 560)

                Label("No TGSpeicher backend • Telegram runs directly on this iPhone", systemImage: "iphone.and.arrow.forward")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer(minLength: 36)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
        }
    }

    private var hero: some View {
        VStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(.blue.gradient)
                    .frame(width: 98, height: 98)
                    .shadow(color: .blue.opacity(0.3), radius: 30, y: 15)
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 5) {
                Text("TGSpeicher")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text("Your private Telegram cloud drive")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Telegram API access", systemImage: "key.fill").font(.headline)
            Text("Use the API ID and API hash from my.telegram.org. They stay in the iPhone Keychain.")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("API ID", text: $apiID)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            SecureField("API Hash", text: $apiHash)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            primaryButton("Save & Connect", icon: "lock.open.fill") {
                telegram.saveAPICredentials(apiIDText: apiID, apiHash: apiHash)
            }
        }
        .tgGlassCard()
    }

    private var connectingCard: some View {
        VStack(spacing: 15) {
            ProgressView().controlSize(.large)
            Text("Connecting securely").font(.headline)
            Text("TDLib is opening the encrypted on-device Telegram session.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry connection", systemImage: "arrow.clockwise") { telegram.retryConnection() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .tgGlassCard()
    }

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Connect Telegram", systemImage: "phone.fill").font(.headline)
            Text("TGSpeicher blocks duplicate code requests so repeated taps cannot invalidate the current login transaction.")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("+49…", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .textFieldStyle(.roundedBorder)
            primaryButton(telegram.isAuthActionInFlight ? "Requesting…" : "Send Login Code", icon: "paperplane.fill") {
                telegram.setPhoneNumber(phone)
            }
            .disabled(telegram.isAuthActionInFlight)
            Divider()
            Button("Login with QR instead", systemImage: "qrcode") { telegram.requestQRLogin() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(telegram.isAuthActionInFlight)
        }
        .tgGlassCard()
    }

    private func codeCard(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Verification code", systemImage: "number.square.fill").font(.headline)
            Text(hint).font(.subheadline).foregroundStyle(.secondary)
            if let info = telegram.loginCodeInfo {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Telegram-selected delivery").font(.caption).foregroundStyle(.secondary)
                        Text(shortDelivery(info.deliveryType)).font(.subheadline.weight(.semibold))
                    }
                }
                .padding(12)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            TextField("Code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
            primaryButton("Verify", icon: "checkmark.circle.fill") { telegram.submitCode(code) }
                .disabled(telegram.isAuthActionInFlight || code.isEmpty)
            if let info = telegram.loginCodeInfo, info.nextDeliveryType != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Button {
                        telegram.resendAuthenticationCode()
                    } label: {
                        Label(
                            info.remainingSeconds > 0
                                ? "\(info.nextDeliveryDescription.map(shortDelivery) ?? "Another method") in \(info.remainingSeconds)s"
                                : "Resend via \(info.nextDeliveryDescription.map(shortDelivery) ?? "another method")",
                            systemImage: "arrow.clockwise"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(info.remainingSeconds > 0 || telegram.isAuthActionInFlight)
                }
            }
            Button("Use QR login", systemImage: "qrcode") { telegram.requestQRLogin() }
                .buttonStyle(.plain).foregroundStyle(.blue)
        }
        .tgGlassCard()
    }

    private func qrCard(link: String) -> some View {
        VStack(spacing: 16) {
            Label("QR login", systemImage: "qrcode.viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Open Telegram on a device where you are already signed in, then scan this from Settings › Devices › Link Desktop Device.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            QRCodeView(text: link)
                .frame(width: 220, height: 220)
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            HStack {
                Button("Copy link", systemImage: "doc.on.doc") { UIPasteboard.general.string = link }
                    .buttonStyle(.bordered)
                Button("Open Telegram", systemImage: "paperplane.fill") {
                    if let url = URL(string: link) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Back to phone login", systemImage: "phone") { telegram.retryConnection() }
                .buttonStyle(.plain).foregroundStyle(.blue)
        }
        .tgGlassCard()
    }

    private func passwordCard(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Two-step verification", systemImage: "lock.shield.fill").font(.headline)
            Text(hint.isEmpty ? "Enter your Telegram 2FA password." : "Password hint: \(hint)")
                .font(.subheadline).foregroundStyle(.secondary)
            SecureField("Telegram password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            primaryButton("Unlock Telegram", icon: "lock.open.fill") { telegram.submitPassword(password) }
                .disabled(password.isEmpty || telegram.isAuthActionInFlight)
        }
        .tgGlassCard()
    }

    private var emailAddressCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Email verification", systemImage: "envelope.fill").font(.headline)
            TextField("Email address", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            primaryButton("Send Email Code", icon: "paperplane.fill") { telegram.submitEmailAddress(email) }
                .disabled(!email.contains("@") || telegram.isAuthActionInFlight)
        }
        .tgGlassCard()
    }

    private func emailCodeCard(pattern: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Email code", systemImage: "envelope.badge.fill").font(.headline)
            Text("Enter the code Telegram sent to \(pattern).")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("Email code", text: $emailCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
            primaryButton("Verify Email", icon: "checkmark.circle.fill") { telegram.submitEmailCode(emailCode) }
                .disabled(emailCode.isEmpty || telegram.isAuthActionInFlight)
        }
        .tgGlassCard()
    }

    private func recoveryCard(title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.largeTitle).foregroundStyle(.orange)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry", systemImage: "arrow.clockwise") { telegram.retryConnection() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .tgGlassCard()
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func shortDelivery(_ value: String) -> String {
        if value.contains("Telegram") { return "Telegram app" }
        if value.localizedCaseInsensitiveContains("sms") { return "SMS" }
        if value.localizedCaseInsensitiveContains("call") { return "Phone call" }
        if value.localizedCaseInsensitiveContains("email") { return "Email" }
        return value.replacingOccurrences(of: "authenticationCodeType", with: "")
    }
}

struct QRCodeView: View {
    let text: String
    var body: some View {
        if let image = makeQRCode(text) {
            Image(uiImage: image).resizable().interpolation(.none)
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().padding(30)
        }
    }

    private func makeQRCode(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Cloud

struct MainCloudView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore

    var body: some View {
        TabView {
            NavigationStack { FolderView(folderID: nil, title: "TG Cloud", cloud: cloud) }
                .tabItem { Label("Cloud", systemImage: "externaldrive.fill.badge.icloud") }
            NavigationStack { TagsView(cloud: cloud) }
                .tabItem { Label("Tags", systemImage: "tag.fill") }
            NavigationStack { DashboardView(telegram: telegram, cloud: cloud) }
                .tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }
            NavigationStack { SettingsView(telegram: telegram, cloud: cloud) }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .overlay(alignment: .bottom) {
            if let upload = cloud.upload {
                UploadPill(progress: upload)
                    .padding(.horizontal)
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring, value: cloud.upload)
        .alert("TGSpeicher", isPresented: Binding(
            get: { cloud.lastError != nil },
            set: { if !$0 { cloud.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { cloud.lastError = nil }
        } message: {
            Text(cloud.lastError ?? "")
        }
    }
}

struct FolderView: View {
    let folderID: UUID?
    let title: String
    @ObservedObject var cloud: CloudStore

    @State private var showingPicker = false
    @State private var newFolderSheet = false
    @State private var folderName = ""
    @State private var searchText = ""

    var body: some View {
        List {
            if folderID == nil {
                Section {
                    HStack(spacing: 14) {
                        stat("Files", "\(cloud.index.files.count)", "doc.fill")
                        stat("Folders", "\(cloud.index.folders.count)", "folder.fill")
                        stat("Cloud", cloud.totalTrackedBytes.byteCountString, "externaldrive.fill")
                    }
                    .padding(.vertical, 7)
                }

                Section {
                    Button {
                        showingPicker = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Choose File")
                                Text("Native iOS document picker • copied locally before upload")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.badge.plus").foregroundStyle(.blue)
                        }
                    }
                    .disabled(cloud.upload != nil)
                }
            }

            if !cloud.folderPath(for: folderID).isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            Image(systemName: "externaldrive.fill").foregroundStyle(.blue)
                            ForEach(cloud.folderPath(for: folderID)) { folder in
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                Text(folder.name).font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }

            if searchText.isEmpty {
                let folders = cloud.children(of: folderID)
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders) { folder in
                            NavigationLink {
                                FolderView(folderID: folder.id, title: folder.name, cloud: cloud)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.name)
                                        Text("\(cloud.children(of: folder.id).count) folders • \(cloud.files(in: folder.id).count) files")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }

            Section(searchText.isEmpty ? "Files" : "Search results") {
                let files = searchText.isEmpty ? cloud.files(in: folderID) : cloud.searchFiles(searchText)
                if files.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No files" : "No matches",
                        systemImage: searchText.isEmpty ? "tray" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "Choose a file above or put one into TGSpeicher's Upload Inbox in the Files app." : "Try another file name or tag.")
                    )
                } else {
                    ForEach(files) { file in
                        NavigationLink {
                            FileDetailView(fileID: file.id, cloud: cloud)
                        } label: {
                            FileRow(file: file, cloud: cloud)
                        }
                    }
                }
            }

            if folderID == nil && !cloud.localInboxFiles.isEmpty {
                Section("Apple Files • Upload Inbox") {
                    ForEach(cloud.localInboxFiles, id: \.self) { url in
                        Button {
                            cloud.uploadFile(url, folderID: nil)
                        } label: {
                            HStack {
                                Image(systemName: "doc.badge.arrow.up").foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).foregroundStyle(.primary)
                                    Text("Upload from On My iPhone › TGSpeicher › Upload Inbox")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(cloud.upload != nil)
                    }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search files or tags")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { cloud.bootstrapFromTelegram() } label: {
                    if cloud.isRefreshing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .disabled(cloud.isRefreshing)
                Menu {
                    Button("Choose File", systemImage: "arrow.up.doc") { showingPicker = true }
                    Button("New Folder", systemImage: "folder.badge.plus") { newFolderSheet = true }
                    Button("Refresh Files Inbox", systemImage: "folder") { cloud.refreshLocalInbox() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .fullScreenCover(isPresented: $showingPicker) {
            TGDocumentPicker(
                onPicked: { urls in
                    showingPicker = false
                    if let url = urls.first {
                        cloud.importPickedFileAndUpload(url, folderID: folderID)
                    } else {
                        cloud.lastError = "The Files app returned no selected file."
                    }
                },
                onCancel: {
                    showingPicker = false
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $newFolderSheet) {
            NavigationStack {
                Form { TextField("Folder name", text: $folderName) }
                    .navigationTitle("New Folder")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { newFolderSheet = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create") {
                                cloud.createFolder(name: folderName, parentID: folderID)
                                folderName = ""
                                newFolderSheet = false
                            }
                            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }

    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(.blue)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.65)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FileRow: View {
    let file: CloudFileEntry
    @ObservedObject var cloud: CloudStore

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(file.tint.opacity(0.11)).frame(width: 46, height: 46)
                Image(systemName: file.symbol)
                    .foregroundStyle(file.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).lineLimit(1)
                HStack(spacing: 5) {
                    Text(file.totalSize.byteCountString)
                    if file.chunks.count > 1 { Text("• \(file.chunks.count) parts") }
                }
                .font(.caption).foregroundStyle(.secondary)
                let names = cloud.tags.filter { file.tagIDs.contains($0.id) }.map(\.name)
                if !names.isEmpty {
                    Text(names.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2.weight(.medium)).foregroundStyle(.blue).lineLimit(1)
                }
            }
        }
    }
}

struct FileDetailView: View {
    let fileID: UUID
    @ObservedObject var cloud: CloudStore
    @State private var rename = ""
    @State private var confirmDelete = false

    private var file: CloudFileEntry? { cloud.index.files.first { $0.id == fileID } }

    var body: some View {
        Form {
            if let file {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "doc.fill").font(.largeTitle).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).font(.headline)
                            Text(file.totalSize.byteCountString).foregroundStyle(.secondary)
                        }
                    }
                    Button("Download & Verify", systemImage: "arrow.down.doc.fill") { cloud.downloadAndReassemble(file) }
                        .disabled(cloud.isDownloading)
                }

                Section("Tags") {
                    if cloud.tags.isEmpty {
                        Text("Create tags in the Tags tab.").foregroundStyle(.secondary)
                    } else {
                        ForEach(cloud.tags) { tag in
                            Button {
                                var ids = file.tagIDs
                                if ids.contains(tag.id) { ids.removeAll { $0 == tag.id } } else { ids.append(tag.id) }
                                cloud.setTags(ids, for: file)
                            } label: {
                                HStack {
                                    Label(tag.name, systemImage: "tag.fill").foregroundStyle(.primary)
                                    Spacer()
                                    if file.tagIDs.contains(tag.id) { Image(systemName: "checkmark").foregroundStyle(.blue) }
                                }
                            }
                        }
                    }
                }

                Section("Folder") {
                    Picker("Location", selection: Binding(
                        get: { file.folderID },
                        set: { cloud.moveFile(file, to: $0) }
                    )) {
                        Text("TG Cloud").tag(UUID?.none)
                        ForEach(cloud.index.folders.sorted { $0.name < $1.name }) { folder in
                            Text(cloud.folderPath(for: folder.id).map(\.name).joined(separator: " / "))
                                .tag(Optional(folder.id))
                        }
                    }
                }

                Section("Rename") {
                    TextField(file.name, text: $rename)
                    Button("Rename") {
                        cloud.renameFile(file, to: rename)
                        rename = ""
                    }
                    .disabled(rename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Integrity") {
                    LabeledContent("Chunks", value: "\(file.chunks.count)")
                    if let hash = file.sha256 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                            Text(hash).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }

                Section {
                    Button("Delete from Telegram", systemImage: "trash.fill", role: .destructive) { confirmDelete = true }
                }
            } else {
                ContentUnavailableView("File not found", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle("File")
        .confirmationDialog("Delete this file from Telegram Saved Messages?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if let file {
                Button("Delete from Telegram", role: .destructive) { cloud.deleteFileFromTelegram(file) }
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

// MARK: - Tags

struct TagsView: View {
    @ObservedObject var cloud: CloudStore
    @State private var newTag = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("New tag", text: $newTag)
                    Button("Add") {
                        cloud.createTag(name: newTag)
                        newTag = ""
                    }
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Tags") {
                if cloud.tags.isEmpty {
                    ContentUnavailableView("No tags", systemImage: "tag", description: Text("Tags are stored in the Telegram catalog and survive reinstallations."))
                } else {
                    ForEach(cloud.tags) { tag in
                        NavigationLink {
                            TagFilesView(tag: tag, cloud: cloud)
                        } label: {
                            Label {
                                HStack {
                                    Text(tag.name)
                                    Spacer()
                                    Text("\(cloud.files(tagged: tag.id).count)").foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "tag.fill").foregroundStyle(.blue)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { cloud.deleteTag(tag) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Tags")
    }
}

struct TagFilesView: View {
    let tag: CloudTag
    @ObservedObject var cloud: CloudStore

    var body: some View {
        List(cloud.files(tagged: tag.id)) { file in
            NavigationLink {
                FileDetailView(fileID: file.id, cloud: cloud)
            } label: {
                FileRow(file: file, cloud: cloud)
            }
        }
        .navigationTitle("#\(tag.name)")
    }
}

// MARK: - Overview / Settings

struct DashboardView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connected as").font(.caption).foregroundStyle(.secondary)
                        Text(telegram.accountName).font(.title2.bold())
                    }
                    Spacer()
                    Image(systemName: "checkmark.icloud.fill").font(.title).foregroundStyle(.green)
                }
                .tgGlassCard()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    MetricCard(title: "Tracked cloud", value: cloud.totalTrackedBytes.byteCountString, icon: "externaldrive.fill")
                    MetricCard(title: "Files", value: "\(cloud.index.files.count)", icon: "doc.fill")
                    MetricCard(title: "Folders", value: "\(cloud.index.folders.count)", icon: "folder.fill")
                    MetricCard(title: "Tags", value: "\(cloud.index.tags.count)", icon: "tag.fill")
                    MetricCard(title: "Chunks", value: "\(cloud.totalChunks)", icon: "square.stack.3d.up.fill")
                    MetricCard(title: "Catalog", value: "r\(cloud.index.revision)", icon: "list.bullet.rectangle.fill")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Recovery catalog", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.icloud.fill")
                        .font(.headline)
                    Text(cloud.catalogStatus).foregroundStyle(.secondary)
                    if let pointer = cloud.catalogPointerMessageID {
                        Text("Pointer message ID: \(pointer)")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tgGlassCard()

                if cloud.isDownloading {
                    HStack { ProgressView(); Text("Downloading and verifying…"); Spacer() }.tgGlassCard()
                }

                if let url = cloud.lastExportURL {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Download ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                        Text(url.lastPathComponent)
                        Text("Saved in On My iPhone › TGSpeicher › Downloads")
                            .font(.caption).foregroundStyle(.secondary)
                        ShareLink(item: url) {
                            Label("Export / Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .tgGlassCard()
                }
            }
            .padding()
        }
        .navigationTitle("Overview")
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon).font(.title2).foregroundStyle(.blue)
            Text(value).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
        .tgGlassCard()
    }
}

struct SettingsView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore
    @State private var recoveryMessageID = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Telegram") {
                LabeledContent("Account", value: telegram.accountName)
                LabeledContent("Authorization", value: telegram.lastAuthorizationStateName)
                Button("Log out from Telegram", systemImage: "rectangle.portrait.and.arrow.right") { telegram.logOut() }
            }

            Section("Recovery Catalog") {
                Text("A pointer message plus a versioned JSON catalog restores folders, tags and final Telegram message IDs without scanning the whole chat.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Status", value: cloud.catalogStatus)
                LabeledContent("Revision", value: "\(cloud.index.revision)")
                if let pointer = cloud.catalogPointerMessageID {
                    Text("Pointer ID: \(pointer)")
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Button("Sync catalog now", systemImage: "arrow.up.doc.on.clipboard") { cloud.syncCatalogNow() }
                    .disabled(cloud.isCatalogSyncing)
                Button("Fast restore / refresh", systemImage: "bolt.fill") { cloud.bootstrapFromTelegram() }
                    .disabled(cloud.isRefreshing)
                Button("Full recovery scan", systemImage: "magnifyingglass") { cloud.fullRebuildFromTelegram() }
                    .disabled(cloud.isRefreshing)
            }

            Section("Manual disaster recovery") {
                TextField("Catalog pointer message ID", text: $recoveryMessageID)
                    .keyboardType(.numberPad)
                Button("Restore from this message ID", systemImage: "arrow.down.doc") {
                    cloud.restoreFromCatalogPointer(recoveryMessageID)
                }
                .disabled(recoveryMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Apple Files") {
                Label("On My iPhone › TGSpeicher › Upload Inbox", systemImage: "folder.badge.plus")
                Label("On My iPhone › TGSpeicher › Downloads", systemImage: "folder.fill")
                Label("On My iPhone › TGSpeicher › Catalog Backups", systemImage: "doc.badge.clock")
                Text("Files picked inside TGSpeicher are copied into Upload Inbox first. This keeps uploads independent from temporary iCloud or third-party File Provider URLs.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Open Files app", systemImage: "folder") {
                    if let url = URL(string: "shareddocuments://") { UIApplication.shared.open(url) }
                }
                Button("Refresh Upload Inbox", systemImage: "arrow.clockwise") { cloud.refreshLocalInbox() }
            }

            Section("Local session") {
                Button("Erase local Telegram login data", systemImage: "trash.fill", role: .destructive) { confirmReset = true }
                Text("This does not delete files stored in Telegram Saved Messages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Erase local Telegram login data?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase Local Telegram Data", role: .destructive) { telegram.resetAPICredentials() }
            Button("Cancel", role: .cancel) { }
        }
    }
}

struct UploadPill: View {
    let progress: UploadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                Text(progress.fileName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(Int(progress.fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
            Text(progress.status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 12, y: 6)
    }
}

extension View {
    @ViewBuilder
    func tgGlassCard() -> some View {
        if #available(iOS 26.0, *) {
            self
                .padding(17)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            self
                .padding(17)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.09), lineWidth: 0.7)
                }
        }
    }
}
