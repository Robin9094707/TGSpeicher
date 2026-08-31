import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            switch telegram.authorizationStage {
            case .ready:
                MainCloudView(telegram: telegram, cloud: cloud)
            default:
                LoginView(telegram: telegram)
            }
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

struct LoginView: View {
    @ObservedObject var telegram: TelegramClient
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var phone = "+49"
    @State private var code = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 30)
                ZStack {
                    Circle()
                        .fill(.blue.gradient)
                        .frame(width: 92, height: 92)
                    Image(systemName: "externaldrive.fill.badge.icloud")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(radius: 20, y: 10)

                VStack(spacing: 7) {
                    Text("TGSpeicher")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("Your private Telegram cloud drive")
                        .foregroundStyle(.secondary)
                }

                Group {
                    switch telegram.authorizationStage {
                    case .apiCredentials:
                        credentialsCard
                    case .connecting:
                        statusCard(title: "Connecting securely", subtitle: "TDLib is opening your encrypted local session.")
                    case .phone:
                        phoneCard
                    case .code(let hint):
                        codeCard(hint: hint)
                    case .password(let hint):
                        passwordCard(hint: hint)
                    case .closed:
                        statusCard(title: "Session closed", subtitle: "Restart TGSpeicher to reconnect.")
                    case .error(let text):
                        statusCard(title: "Additional verification required", subtitle: text)
                    case .ready:
                        EmptyView()
                    }
                }
                .frame(maxWidth: 520)

                Text("No TGSpeicher backend • Telegram connection runs directly on this iPhone")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer(minLength: 30)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Telegram API access", systemImage: "key.fill")
                .font(.headline)
            Text("Telegram requires every independent client to use an API ID and API hash. Create yours once at my.telegram.org, then TGSpeicher stores it in the iPhone Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("API ID", text: $apiID)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            SecureField("API Hash", text: $apiHash)
                .textFieldStyle(.roundedBorder)

            primaryButton("Save & Connect", systemImage: "lock.open.fill") {
                telegram.saveAPICredentials(apiIDText: apiID, apiHash: apiHash)
            }
        }
        .tgGlassCard()
    }

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Connect Telegram", systemImage: "phone.fill")
                .font(.headline)
            Text("Enter the phone number of your own Telegram account in international format.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("+49…", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .textFieldStyle(.roundedBorder)
            primaryButton("Send Login Code", systemImage: "paperplane.fill") {
                telegram.setPhoneNumber(phone)
            }
        }
        .tgGlassCard()
    }

    private func codeCard(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Verification code", systemImage: "number.square.fill")
                .font(.headline)
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
            primaryButton("Verify", systemImage: "checkmark.circle.fill") {
                telegram.submitCode(code)
            }
        }
        .tgGlassCard()
    }

    private func passwordCard(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Two-step verification", systemImage: "lock.shield.fill")
                .font(.headline)
            Text(hint.isEmpty ? "Enter your Telegram 2FA password." : "Password hint: \(hint)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SecureField("Telegram password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            primaryButton("Unlock Telegram", systemImage: "lock.open.fill") {
                telegram.submitPassword(password)
            }
        }
        .tgGlassCard()
    }

    private func statusCard(title: String, subtitle: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .tgGlassCard()
    }
}

struct MainCloudView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore

    var body: some View {
        TabView {
            NavigationStack {
                FolderView(folderID: nil, title: "TG Cloud", cloud: cloud)
            }
            .tabItem { Label("Cloud", systemImage: "externaldrive.fill.badge.icloud") }

            NavigationStack {
                DashboardView(telegram: telegram, cloud: cloud)
            }
            .tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }

            NavigationStack {
                SettingsView(telegram: telegram, cloud: cloud)
            }
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

    @State private var importer = false
    @State private var newFolderSheet = false
    @State private var folderName = ""

    var body: some View {
        List {
            if folderID == nil {
                Section {
                    HStack(spacing: 16) {
                        stat(icon: "shippingbox.fill", value: "\(cloud.index.files.count)", caption: "Files")
                        stat(icon: "square.stack.3d.up.fill", value: "\(cloud.totalChunks)", caption: "Chunks")
                        stat(icon: "externaldrive.fill", value: cloud.totalTrackedBytes.byteCountString, caption: "Tracked")
                    }
                    .padding(.vertical, 8)
                }
            }

            let folders = cloud.children(of: folderID)
            if !folders.isEmpty {
                Section("Folders") {
                    ForEach(folders) { folder in
                        NavigationLink {
                            FolderView(folderID: folder.id, title: folder.name, cloud: cloud)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(folder.name)
                                    Text("\(cloud.children(of: folder.id).count) folders • \(cloud.files(in: folder.id).count) files")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }

            Section("Files") {
                let files = cloud.files(in: folderID)
                if files.isEmpty {
                    ContentUnavailableView("No files", systemImage: "tray", description: Text("Upload a file to store it in Telegram Saved Messages."))
                } else {
                    ForEach(files) { file in
                        FileRow(file: file, cloud: cloud)
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    cloud.refreshFromTelegram()
                } label: {
                    if cloud.isRefreshing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                Button {
                    importer = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(cloud.upload != nil)
                Menu {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderSheet = true
                    }
                    Button("Upload File", systemImage: "arrow.up.doc") {
                        importer = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { cloud.uploadFile(url, folderID: folderID) }
            case .failure(let error):
                cloud.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $newFolderSheet) {
            NavigationStack {
                Form {
                    TextField("Folder name", text: $folderName)
                }
                .navigationTitle("New Folder")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { newFolderSheet = false }
                    }
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

    private func stat(icon: String, value: String, caption: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(.blue)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
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
                    .fill(.blue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: file.chunks.count > 1 ? "square.stack.3d.up.fill" : "doc.fill")
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(file.totalSize.byteCountString)
                    if file.chunks.count > 1 {
                        Text("• \(file.chunks.count) parts")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Download & Reassemble", systemImage: "arrow.down.doc") {
                    cloud.downloadAndReassemble(file)
                }
                Button("Remove from local index", systemImage: "eye.slash", role: .destructive) {
                    cloud.deleteLocalIndexEntry(file)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .padding(8)
            }
        }
    }
}

struct DashboardView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Connected as")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(telegram.accountName)
                                .font(.title2.bold())
                        }
                        Spacer()
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                    }
                    Divider()
                    Text("Telegram storage is unlimited overall. TGSpeicher tracks the files indexed by this app and automatically keeps each upload chunk below the standard per-file limit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .tgGlassCard()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    MetricCard(title: "Tracked cloud", value: cloud.totalTrackedBytes.byteCountString, icon: "externaldrive.fill")
                    MetricCard(title: "Files", value: "\(cloud.index.files.count)", icon: "doc.fill")
                    MetricCard(title: "Folders", value: "\(cloud.index.folders.count)", icon: "folder.fill")
                    MetricCard(title: "Chunks", value: "\(cloud.totalChunks)", icon: "square.stack.3d.up.fill")
                }

                if cloud.isDownloading {
                    HStack {
                        ProgressView()
                        Text("Downloading and rebuilding file…")
                        Spacer()
                    }
                    .tgGlassCard()
                }

                if let url = cloud.lastExportURL {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("File ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.headline)
                        Text(url.lastPathComponent)
                            .font(.subheadline)
                        ShareLink(item: url) {
                            Label("Export / Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
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
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }
}

struct SettingsView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore
    @State private var showReset = false

    var body: some View {
        Form {
            Section("Telegram") {
                LabeledContent("Account", value: telegram.accountName)
                LabeledContent("Storage target", value: "Saved Messages")
                Button("Refresh TGSpeicher index", systemImage: "arrow.triangle.2.circlepath") {
                    cloud.refreshFromTelegram()
                }
            }
            Section("Privacy") {
                Label("No TGSpeicher server backend", systemImage: "checkmark.shield.fill")
                Label("API hash stored in iPhone Keychain", systemImage: "key.fill")
                Label("TDLib database encrypted locally", systemImage: "lock.fill")
            }
            Section("Compatibility") {
                LabeledContent("Chunk target", value: "1.9 GB")
                Text("Using 1.9 GB parts keeps uploads compatible with Telegram's standard 2 GB per-file limit. Telegram Premium can accept larger individual files, but smaller chunks remain portable across account tiers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Log out of Telegram", role: .destructive) {
                    telegram.logOut()
                }
                Button("Reset API credentials", role: .destructive) {
                    showReset = true
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset Telegram API credentials?", isPresented: $showReset, titleVisibility: .visible) {
            Button("Reset credentials", role: .destructive) {
                telegram.resetAPICredentials()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears the locally stored API ID/hash and TDLib session from this iPhone. Your Telegram cloud files remain in Saved Messages.")
        }
    }
}

struct UploadPill: View {
    let progress: UploadProgress

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.circular)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.fileName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(progress.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if progress.partCount > 1 {
                Text("\(max(1, progress.currentPart))/\(progress.partCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .tgGlassCard(padding: 0)
        .shadow(radius: 12, y: 5)
    }
}

@ViewBuilder
private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    let button = Button(action: action) {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
    if #available(iOS 26.0, *) {
        button.buttonStyle(.glassProminent)
    } else {
        button.buttonStyle(.borderedProminent)
    }
}

extension View {
    @ViewBuilder
    func tgGlassCard(padding: CGFloat = 18) -> some View {
        if #available(iOS 26.0, *) {
            self
                .padding(padding)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            self
                .padding(padding)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}
