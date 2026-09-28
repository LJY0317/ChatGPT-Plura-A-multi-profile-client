import Foundation
import Observation
import PhotosUI
import Security
import SwiftUI
import UniformTypeIdentifiers

struct RemoteHomeView: View {
    private enum Surface: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case work = "Work"
        case codex = "Codex"

        var id: Self { self }

        var icon: String {
            switch self {
            case .chat: "bubble.left.and.bubble.right"
            case .work: "briefcase"
            case .codex: "desktopcomputer"
            }
        }

        var composerPlaceholder: String {
            switch self {
            case .chat: "Ask ChatGPT"
            case .work: "Ask Work"
            case .codex: "Ask Codex"
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var store = RemoteCodexStore()
    @AppStorage("codexRemote.surface") private var surfaceRawValue = Surface.chat.rawValue
    @State private var showsSidebar = false
    @State private var showsConnectionSettings = false
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var didRunLaunchAutomation = false
    @State private var selectedCloudPhoto: PhotosPickerItem?
    @State private var showsCloudFileImporter = false
    @State private var showsFastChatRelaunchConfirmation = false

    private var surface: Surface {
        Surface(rawValue: surfaceRawValue) ?? .chat
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                if store.showingThreadList {
                    listContextHeader
                }
                if isSearching && store.showingThreadList {
                    searchBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                connectionBanner
                mainContent
            }
            .background(Color(uiColor: .systemBackground))

            if showsSidebar {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { showsSidebar = false } }
                    .transition(.opacity)

                sidebar
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsSidebar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { navigationToolbar }
        .onChange(of: scenePhase) { _, phase in
            store.handleScenePhase(phase)
        }
        .onAppear {
            guard !didRunLaunchAutomation else { return }
            didRunLaunchAutomation = true
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            Task {
                await store.runLaunchAutomationIfRequested()
                if store.hasSavedPairing, !store.isConnected, !store.isConnecting {
                    store.connect(preservingPresentation: store.hasPresentationContent)
                }
            }
        }
        .alert(item: $store.approvalPrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.detail),
                primaryButton: .default(Text("Allow")) { store.respondToApproval(allow: true) },
                secondaryButton: .destructive(Text("Deny")) { store.respondToApproval(allow: false) }
            )
        }
        .confirmationDialog(
            "Relaunch ChatGPT for Fast Chat?",
            isPresented: $showsFastChatRelaunchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Quit & Relaunch ChatGPT") { store.prepareFastChat() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Plura Mobile will ask Plura Desktop to quit this exact ChatGPT profile normally, then relaunch it with the best available Chat mirror. An unsent Mac draft or in-progress response may be interrupted.")
        }
        .sheet(item: $store.userInputPrompt) { prompt in
            RemoteUserInputSheet(
                prompt: prompt,
                onSubmit: { answers in store.respondToUserInput(answers: answers) },
                onCancel: { store.respondToUserInput(answers: [:], cancelled: true) }
            )
        }
        .sheet(item: $store.mcpElicitationPrompt) { prompt in
            RemoteMcpElicitationSheet(
                prompt: prompt,
                onSubmit: { values in store.respondToMcpElicitation(values: values) },
                onCancel: { store.respondToMcpElicitation(values: [:], cancelled: true) }
            )
        }
        .sheet(isPresented: $showsConnectionSettings) {
            connectionSettingsSheet
        }
        .onChange(of: selectedCloudPhoto) { _, item in
            guard let item else { return }
            loadCloudPhoto(item)
        }
        .fileImporter(
            isPresented: $showsCloudFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { loadCloudFile(url) }
            case .failure(let error):
                store.lastError = error.localizedDescription
            }
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if store.showingThreadList {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showsSidebar = true }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel("Open menu")
            } else {
                Button { store.showConversations() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!store.canSwitchThreads)
                .accessibilityLabel("Back to conversations")
            }
        }

        ToolbarItem(placement: .principal) {
            if store.showingThreadList {
                if surface == .codex {
                    Text("Codex")
                        .font(.headline)
                } else {
                    Picker("Mode", selection: surfaceBinding) {
                        Text("Chat").tag(Surface.chat)
                        Text("Work").tag(Surface.work)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .accessibilityIdentifier("pluraSurfacePicker")
                }
            } else {
                VStack(spacing: 1) {
                    Text(store.navigationTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if store.hasMultipleTargets {
                        Text(store.selectedTargetPresentationName ?? surface.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if store.showingThreadList {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isSearching.toggle() }
                } label: {
                    Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                }
                .accessibilityLabel("Search conversations")
            } else if store.isCloudChatMirror {
                Button { store.refreshActiveCloudChat() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoadingCloudTranscript)
                .accessibilityLabel("Refresh Desktop chat")
            } else {
                modelMenu
            }
        }
    }

    private var listContextHeader: some View {
        VStack(spacing: 8) {
            targetChrome
            if surface == .chat, store.selectedTarget?.chatMirrorNeedsRelaunch == true {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle")
                    Text("Fast Chat needs one normal ChatGPT relaunch.")
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if store.isPreparingFastChat {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Relaunch") {
                            showsFastChatRelaunchConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!store.canPrepareFastChat)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Fast Chat requires one normal ChatGPT relaunch")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var targetChrome: some View {
        if store.hasMultipleTargets {
            profileMenu
        } else {
            HStack(spacing: 7) {
                Circle().fill(store.statusColor).frame(width: 7, height: 7)
                Text(store.selectedTargetPresentationName ?? (store.hasSavedPairing ? "ChatGPT" : "Set up Mac"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(targetConnectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var targetConnectionLabel: String {
        switch store.state {
        case .disconnected:
            store.hasSavedPairing ? "Offline" : "Not set up"
        case .connecting:
            "Connecting"
        case .ready:
            "Connected"
        case .running:
            "Working"
        case .failed:
            "Unavailable"
        }
    }

    private var surfaceBinding: Binding<Surface> {
        Binding(
            get: { surface == .codex ? .chat : surface },
            set: { selectSurface($0) }
        )
    }

    private var profileMenu: some View {
        Menu {
            if store.targets.isEmpty {
                Text(store.hasSavedPairing ? "No profiles loaded" : "Pair a Mac first")
            } else {
                ForEach(store.targets) { target in
                    Button {
                        store.selectTarget(target)
                    } label: {
                        if store.selectedTargetID == target.id {
                            Label(target.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(target.menuTitle)
                        }
                    }
                }
            }
            Divider()
            Button { store.refreshTargets() } label: {
                Label("Refresh Profiles", systemImage: "arrow.clockwise")
            }
            .disabled(!store.hasSavedPairing || store.isLoadingTargets)
            Button { showsConnectionSettings = true } label: {
                Label("Connection Settings", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(store.statusColor).frame(width: 7, height: 7)
                Text(store.selectedTargetPresentationName ?? (store.hasSavedPairing ? "Mac profile" : "Set up Mac"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(targetConnectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search conversations", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var connectionBanner: some View {
        switch store.state {
        case .ready, .running:
            EmptyView()
        case .connecting:
            connectionNotice(
                systemName: "arrow.trianglehead.2.clockwise.rotate.90",
                title: store.hasPresentationContent ? "Reconnecting to your Mac" : "Connecting to your Mac",
                detail: store.hasPresentationContent ? "Showing saved content while Plura Host reconnects." : "Looking for your saved Plura Host connection.",
                showsProgress: true,
                retryAction: nil
            )
        case .failed:
            connectionNotice(
                systemName: "exclamationmark.triangle",
                title: "Mac connection unavailable",
                detail: store.hasPresentationContent ? "Saved content stays available. Retry when your Mac is reachable." : "Check that Plura Host is running and reachable.",
                showsProgress: false,
                retryAction: { store.connect(preservingPresentation: store.hasPresentationContent) }
            )
        case .disconnected:
            if store.hasSavedPairing {
                connectionNotice(
                    systemName: "desktopcomputer",
                    title: "Mac is offline",
                    detail: store.hasPresentationContent ? "Showing saved content until the connection returns." : "Reconnect to load your profiles and conversations.",
                    showsProgress: false,
                    retryAction: { store.connect(preservingPresentation: store.hasPresentationContent) }
                )
            }
        }
    }

    private func connectionNotice(
        systemName: String,
        title: String,
        detail: String,
        showsProgress: Bool,
        retryAction: (() -> Void)?
    ) -> some View {
        HStack(spacing: 11) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let retryAction {
                Button("Retry", action: retryAction)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isConnecting)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private var mainContent: some View {
        if store.isConnected || store.hasPresentationContent {
            if store.showingThreadList {
                threadLibrary
            } else {
                conversationView
            }
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 42))
                    .foregroundStyle(.tertiary)
                Text(store.hasSavedPairing ? "Your Mac is unavailable" : "Connect your Mac")
                    .font(.title3.weight(.semibold))
                Text(store.hasSavedPairing
                    ? "Your profiles and conversations will appear automatically when Plura Host is reachable."
                    : "Pair Plura Mobile with your desktop host once. Connection details stay out of the way after setup.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button(store.hasSavedPairing ? "Retry Connection" : "Connection Settings") {
                    if store.hasSavedPairing {
                        store.connect()
                    } else {
                        showsConnectionSettings = true
                    }
                }
                .buttonStyle(.borderedProminent)
                if store.hasSavedPairing {
                    Button("Connection Settings") { showsConnectionSettings = true }
                        .font(.subheadline)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    private var threadLibrary: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    surfaceContext
                    libraryContent

                    if let error = store.lastError {
                        errorNotice(error)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }

                    Color.clear.frame(height: store.isConnected ? 108 : 24)
                }
            }
            .scrollIndicators(.hidden)
            .refreshable {
                if surface == .chat {
                    store.refreshChatCatalog()
                } else {
                    store.refreshThreads()
                }
            }

            if store.isConnected {
                newThreadComposer
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }

            if store.isOpeningThread {
                ProgressView("Opening…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if surface == .chat, store.hasLoadedChatCatalog || store.isLoadingChatCatalog {
            if store.isLoadingChatCatalog && store.chatCatalogEntries.isEmpty {
                librarySkeleton
            } else if filteredChatCatalogEntries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No chats yet" : "No results",
                    systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "No Desktop chats are currently available." : "Try a different search term.")
                )
                .padding(.top, 40)
            } else {
                ForEach(chatCatalogGroups, id: \.title) { group in
                    librarySectionHeader(
                        title: group.title,
                        systemImage: group.isProject ? "folder.fill" : (group.title == "Pinned" ? "pin.fill" : "clock"),
                        count: group.entries.count
                    )

                    ForEach(group.entries) { entry in
                        chatCatalogRow(entry, insideProject: group.isProject)
                        Divider().padding(.leading, 64)
                    }
                }
            }
        } else if store.isLoadingThreads && filteredThreads.isEmpty {
            librarySkeleton
        } else if filteredThreads.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No conversations yet" : "No results",
                systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                description: Text(searchText.isEmpty ? "Start a conversation below." : "Try a different search term.")
            )
            .padding(.top, 40)
        } else {
            ForEach(threadGroups, id: \.title) { group in
                librarySectionHeader(title: group.title, systemImage: "clock", count: group.threads.count)

                ForEach(group.threads) { thread in
                    threadRow(thread)
                    Divider().padding(.leading, 64)
                }
            }

            if surface != .chat, store.hasMoreThreads && searchText.isEmpty {
                Button("Load more") { store.loadMoreThreads() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .disabled(store.isLoadingThreads)
            }
        }
    }

    @ViewBuilder
    private var surfaceContext: some View {
        switch surface {
        case .chat:
            EmptyView()
        case .work:
            HStack(spacing: 10) {
                Image(systemName: "briefcase")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Work")
                        .font(.headline)
                    Text("Tasks and conversations exposed by this profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        case .codex:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "desktopcomputer")
                    Text(store.selectedTarget?.displayName ?? "Mac")
                        .lineLimit(1)
                    Spacer()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack(spacing: 9) {
                    Image(systemName: "folder")
                    Text(codexWorkingDirectoryLabel)
                        .lineLimit(1)
                    Spacer()
                    Button("Change") { showsConnectionSettings = true }
                        .font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    private func threadRow(_ thread: RemoteThreadSummary) -> some View {
        Button { store.openThread(thread) } label: {
            HStack(alignment: .top, spacing: 12) {
                libraryRowIcon(systemName: surface == .codex ? "terminal" : "briefcase")

                VStack(alignment: .leading, spacing: 6) {
                    Text(thread.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if !thread.preview.isEmpty && thread.preview != thread.title {
                        Text(thread.preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if surface != .chat, let project = thread.projectLabel {
                            Label(project, systemImage: "folder")
                                .lineLimit(1)
                        } else if let model = thread.model {
                            Text(store.modelDisplayName(for: model)).lineLimit(1)
                        }
                        Spacer()
                        Text(thread.updatedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isOpeningThread || !store.canSwitchThreads)
    }

    @ViewBuilder
    private func chatCatalogRow(_ entry: RemoteChatCatalogEntry, insideProject: Bool) -> some View {
        let content = HStack(alignment: .top, spacing: 12) {
            libraryRowIcon(systemName: insideProject ? "bubble.left.fill" : "bubble.left")

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if !insideProject, let projectName = entry.projectName {
                        Label(projectName, systemImage: "folder")
                            .lineLimit(1)
                    } else if insideProject {
                        Text("Project chat")
                    } else {
                        Text("ChatGPT")
                    }
                    if !entry.canOpenRemotely {
                        Text("Mirror")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(entry.updatedDate, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .contentShape(Rectangle())

        Button { store.openChatCatalogEntry(entry) } label: { content }
            .buttonStyle(.plain)
            .disabled(store.isOpeningThread || store.isLoadingCloudTranscript || !store.canSwitchThreads)
    }

    private var newThreadComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                modelMenuContents
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .disabled(!store.canSwitchThreads)

            TextField(surface.composerPlaceholder, text: $store.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit(store.startNewThreadFromDraft)

            Button(action: store.startNewThreadFromDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.35) : Color.primary, in: Circle())
            }
            .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canSwitchThreads)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
    }

    private func librarySectionHeader(title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 7)
    }

    private func libraryRowIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var librarySkeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: index.isMultiple(of: 2) ? 190 : 235, height: 14)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: index.isMultiple(of: 3) ? 110 : 145, height: 10)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
            }
        }
        .accessibilityHidden(true)
    }

    private var modelMenu: some View {
        Menu {
            modelMenuContents
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .medium))
        }
        .disabled(!store.canSwitchThreads)
        .accessibilityLabel("Model settings")
    }

    @ViewBuilder
    private var modelMenuContents: some View {
        if store.models.isEmpty {
            Text("No models available")
        } else {
            ForEach(store.models) { model in
                Button {
                    store.selectModel(model)
                } label: {
                    if store.selectedModel == model.model {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        }
        Divider()
        Button { store.refreshModels() } label: {
            Label("Refresh Models", systemImage: "arrow.clockwise")
        }
    }

    private var sidebar: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Plura Mobile")
                        .font(.title2.weight(.bold))
                        .accessibilityLabel("Plura Mobile")
                        .accessibilityIdentifier("sidebarTitle")
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showsSidebar = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        sidebarNavigationRow(.chat)
                        sidebarNavigationRow(.work)
                        sidebarNavigationRow(.codex)

                        if store.hasMultipleTargets {
                            Divider().padding(.vertical, 10)

                            Text("Profiles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)

                            ForEach(store.targets) { target in
                                Button {
                                    store.selectTarget(target)
                                    withAnimation(.easeOut(duration: 0.18)) { showsSidebar = false }
                                } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: target.activationSystemImage)
                                            .frame(width: 22)
                                        Text(store.targetPresentationName(target))
                                            .lineLimit(1)
                                        Spacer()
                                        if store.selectedTargetID == target.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 14)
                                    .frame(height: 46)
                                    .background(store.selectedTargetID == target.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(!store.canChangeTarget)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }

                Divider()
                VStack(spacing: 4) {
                    Button {
                        showsConnectionSettings = true
                        withAnimation(.easeOut(duration: 0.18)) { showsSidebar = false }
                    } label: {
                        HStack(spacing: 11) {
                            Circle().fill(store.statusColor).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connection")
                                Text(store.statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebarConnection")

                    ShareLink(item: store.diagnosticsURL) {
                        Label("Export diagnostics", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .frame(width: min(proxy.size.width * 0.86, 360), height: proxy.size.height)
            .background(.background)
            .shadow(color: .black.opacity(0.12), radius: 24, x: 8)
        }
    }

    private func sidebarNavigationRow(_ item: Surface) -> some View {
        Button {
            selectSurface(item)
            withAnimation(.easeOut(duration: 0.18)) { showsSidebar = false }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon).frame(width: 22)
                Text(item.rawValue)
                Spacer()
                if surface == item { Image(systemName: "checkmark") }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(surface == item ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebarSurface.\(item.rawValue.lowercased())")
    }

    private var conversationView: some View {
        VStack(spacing: 0) {
            ChatTranscriptView(messages: store.messages, onLoadEarlier: store.loadEarlierTurns)
                .ignoresSafeArea(.keyboard, edges: .bottom)
            if store.isCloudChatMirror {
                VStack(spacing: 0) {
                    if let error = store.lastError {
                        errorNotice(error)
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                    }
                    cloudMirrorBar
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                    if store.cloudChatCanSendText {
                        remoteComposer
                            .padding(.horizontal, 18)
                            .padding(.bottom, 12)
                            .padding(.top, 6)
                    } else {
                        Color.clear.frame(height: 12)
                    }
                }
                .background(.regularMaterial)
                .overlay(alignment: .top) {
                    conversationFooterSeparator
                }
            } else {
                remoteComposer
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
                    .background(.regularMaterial)
                    .overlay(alignment: .top) {
                        conversationFooterSeparator
                    }
            }
        }
        .safeAreaPadding(.bottom, 2)
    }

    private var cloudMirrorBar: some View {
        HStack(spacing: 8) {
            if store.isLoadingCloudTranscript {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: store.cloudChatActivity == "streaming" ? "ellipsis.message" : "checkmark.circle")
                    .foregroundStyle(store.cloudChatActivity == "streaming" ? .orange : .secondary)
            }
            Text(store.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                store.refreshActiveCloudChat()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isLoadingCloudTranscript)
            .accessibilityLabel("Refresh Desktop chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
    }

    private var remoteComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isCloudChatMirror && (!store.stagedCloudAttachments.isEmpty || store.isUploadingCloudAttachment) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.stagedCloudAttachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                                    .foregroundStyle(.secondary)
                                Text(attachment.filename)
                                    .lineLimit(1)
                                Button {
                                    store.removeCloudAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(attachment.filename)")
                            }
                            .font(.caption)
                            .padding(.leading, 10)
                            .padding(.trailing, 7)
                            .frame(minHeight: 30)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                            .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
                        }
                        if store.isUploadingCloudAttachment {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Uploading")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        }
                    }
                }
                .accessibilityLabel("Message attachments")
            }

            if let composerStatus = store.composerStatusText {
                HStack(spacing: 6) {
                    if store.isSendingCloudMessage || store.isUploadingCloudAttachment {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: store.cloudChatActivity == "streaming" ? "ellipsis.message" : "exclamationmark.circle")
                    }
                    Text(composerStatus)
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .bottom, spacing: 10) {
                if store.isCloudChatMirror && store.cloudChatCanAttach {
                    Menu {
                        PhotosPicker(selection: $selectedCloudPhoto, matching: .images) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showsCloudFileImporter = true
                        } label: {
                            Label("Files", systemImage: "doc")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    }
                    .disabled(!store.canStageCloudAttachment)
                    .accessibilityLabel("Add attachment")
                }

                TextField(surface.composerPlaceholder, text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit(store.sendDraft)
                    .accessibilityIdentifier("remoteComposerField")
                Button(action: store.sendDraft) {
                    Group {
                        if store.isSendingCloudMessage {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(store.canSend ? .white : .secondary)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(
                        store.canSend ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                        in: Circle()
                    )
                }
                .disabled(!store.canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
    }

    private var conversationFooterSeparator: some View {
        Rectangle()
            .fill(Color(uiColor: .separator).opacity(0.28))
            .frame(height: 1 / UIScreen.main.scale)
    }

    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.top, 1)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var connectionSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("State", value: store.statusText)
                    LabeledContent(
                        store.hasMultipleTargets ? "Profile" : "Desktop",
                        value: store.selectedTargetPresentationName ?? "None"
                    )
                    Button(store.isConnected ? "Disconnect" : "Connect") {
                        store.isConnected
                            ? store.disconnect()
                            : store.connect(preservingPresentation: store.hasPresentationContent)
                    }
                    .disabled(store.isConnecting || (!store.hasSavedPairing && store.capabilityToken.isEmpty))
                }

                if store.hasMultipleTargets {
                    Section("Profiles") {
                        ForEach(store.targets) { target in
                            Button {
                                store.selectTarget(target)
                            } label: {
                                HStack {
                                    Label(store.targetPresentationName(target), systemImage: target.activationSystemImage)
                                    Spacer()
                                    if store.selectedTargetID == target.id { Image(systemName: "checkmark") }
                                }
                            }
                            .disabled(!store.canChangeTarget)
                        }
                        Button("Refresh Profiles", systemImage: "arrow.clockwise") { store.refreshTargets() }
                            .disabled(!store.hasSavedPairing || store.isLoadingTargets)
                    }
                }

                Section("Codex defaults") {
                    TextField("Mac working directory", text: $store.workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Connection") {
                    if !store.hasSavedPairing {
                        TextField("ws://Mac-IP:8765", text: $store.serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("Pairing token", text: $store.capabilityToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("The token is stored in this iPhone's Keychain after the first successful connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        DisclosureGroup("Advanced connection details") {
                            TextField("Host URL", text: $store.serverURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            ForEach(store.connectionEndpoints) { endpoint in
                                LabeledContent(endpoint.label, value: endpoint.url)
                                    .font(.caption)
                            }
                        }
                        Button("Forget Pairing", role: .destructive) { store.forgetPairing() }
                    }
                }

                Section("Diagnostics") {
                    ShareLink(item: store.diagnosticsURL) {
                        Label("Export Remote Log", systemImage: "square.and.arrow.up")
                    }
                    Button("Clear Remote Log", role: .destructive) { store.clearDiagnostics() }
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showsConnectionSettings = false }
                }
            }
        }
    }

    private var filteredThreads: [RemoteThreadSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = surface == .chat && !store.hasLoadedChatCatalog
            ? store.threads.filter { $0.source == "vscode" }
            : store.threads
        guard !query.isEmpty else { return base }
        return base.filter { thread in
            thread.title.localizedCaseInsensitiveContains(query)
                || thread.preview.localizedCaseInsensitiveContains(query)
                || (thread.projectLabel?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var filteredChatCatalogEntries: [RemoteChatCatalogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.chatCatalogEntries }
        return store.chatCatalogEntries.filter { entry in
            entry.title.localizedCaseInsensitiveContains(query)
                || (entry.projectName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var chatCatalogGroups: [(title: String, isProject: Bool, entries: [RemoteChatCatalogEntry])] {
        let entries = filteredChatCatalogEntries
        let projectByID = Dictionary(uniqueKeysWithValues: store.chatProjects.map { ($0.id, $0) })
        var grouped: [String: [RemoteChatCatalogEntry]] = [:]
        var unassigned: [RemoteChatCatalogEntry] = []
        for entry in entries {
            if let projectID = entry.projectId {
                grouped[projectID, default: []].append(entry)
            } else {
                unassigned.append(entry)
            }
        }

        let projectGroups = grouped.map { projectID, values in
            let project = projectByID[projectID]
            return (
                title: project?.name ?? values.first?.projectName ?? "Project",
                isProject: true,
                isPinned: project?.isPinned ?? false,
                sortOrder: project?.sortOrder,
                entries: values
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.isPinned, rhs.isPinned, lhs.sortOrder != rhs.sortOrder {
                return (lhs.sortOrder ?? Int.max) < (rhs.sortOrder ?? Int.max)
            }
            let lhsDate = lhs.entries.first?.updatedAt ?? 0
            let rhsDate = rhs.entries.first?.updatedAt ?? 0
            return lhsDate > rhsDate
        }
        .map { (title: $0.title, isProject: true, entries: $0.entries) }

        let pinnedChats = unassigned.filter(\.isPinned)
        let recentChats = unassigned.filter { !$0.isPinned }
        var result = projectGroups
        if !pinnedChats.isEmpty {
            result.append((title: "Pinned", isProject: false, entries: pinnedChats))
        }
        if !recentChats.isEmpty {
            result.append((title: "Recent chats", isProject: false, entries: recentChats))
        }
        return result
    }

    private var threadGroups: [(title: String, threads: [RemoteThreadSummary])] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        var today: [RemoteThreadSummary] = []
        var recent: [RemoteThreadSummary] = []
        var older: [RemoteThreadSummary] = []

        for thread in filteredThreads {
            if calendar.isDateInToday(thread.updatedAt) {
                today.append(thread)
            } else if thread.updatedAt >= sevenDaysAgo {
                recent.append(thread)
            } else {
                older.append(thread)
            }
        }

        return [
            ("Today", today),
            ("Previous 7 days", recent),
            ("Earlier", older)
        ].filter { !$0.threads.isEmpty }
    }

    private var codexWorkingDirectoryLabel: String {
        let trimmed = store.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Default working directory" }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private func loadCloudPhoto(_ item: PhotosPickerItem) {
        let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
        let mimeType = contentType.preferredMIMEType ?? "image/jpeg"
        let fileExtension = contentType.preferredFilenameExtension ?? "jpg"
        Task {
            defer { selectedCloudPhoto = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    store.lastError = "The selected photo could not be loaded."
                    return
                }
                guard data.count <= 25 * 1024 * 1024 else {
                    store.lastError = "Attachments are limited to 25 MB each."
                    return
                }
                store.stageCloudAttachment(
                    filename: "Photo-\(UUID().uuidString.lowercased()).\(fileExtension)",
                    mimeType: mimeType,
                    data: data
                )
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    private func loadCloudFile(_ url: URL) {
        Task {
            do {
                let payload = try await Task.detached(priority: .userInitiated) { () -> (String, String, Data) in
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessed { url.stopAccessingSecurityScopedResource() }
                    }
                    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                    if let fileSize = values.fileSize, fileSize > 25 * 1024 * 1024 {
                        throw NSError(
                            domain: "ChatGPTPlura.Attachment",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Attachments are limited to 25 MB each."]
                        )
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    if data.count > 25 * 1024 * 1024 {
                        throw NSError(
                            domain: "ChatGPTPlura.Attachment",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Attachments are limited to 25 MB each."]
                        )
                    }
                    return (
                        url.lastPathComponent,
                        values.contentType?.preferredMIMEType ?? "application/octet-stream",
                        data
                    )
                }.value
                store.stageCloudAttachment(filename: payload.0, mimeType: payload.1, data: payload.2)
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    private func selectSurface(_ newSurface: Surface) {
        surfaceRawValue = newSurface.rawValue
        if !store.showingThreadList, store.canSwitchThreads {
            store.showConversations()
        }
    }
}

private struct RemoteUserInputSheet: View {
    private static let otherValue = "__chatgpt_plura_other__"

    let prompt: RemoteUserInputPrompt
    let onSubmit: ([String: [String]]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var answers: [String: String]
    @State private var otherAnswers: [String: String] = [:]

    init(
        prompt: RemoteUserInputPrompt,
        onSubmit: @escaping ([String: [String]]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _answers = State(initialValue: Dictionary(uniqueKeysWithValues: prompt.questions.map { question in
            (question.id, question.options.first?.label ?? "")
        }))
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(prompt.questions) { question in
                    Section {
                        Text(question.question)
                            .font(.body)
                        if question.options.isEmpty {
                            answerField(question: question, text: binding(for: question.id))
                        } else {
                            Picker("Answer", selection: binding(for: question.id)) {
                                ForEach(question.options) { option in
                                    VStack(alignment: .leading) {
                                        Text(option.label)
                                    }
                                    .tag(option.label)
                                }
                                if question.isOther {
                                    Text("Other…").tag(Self.otherValue)
                                }
                            }
                            if answers[question.id] == Self.otherValue {
                                answerField(question: question, text: otherBinding(for: question.id))
                            }
                            if let selected = question.options.first(where: { $0.label == answers[question.id] }),
                               !selected.description.isEmpty {
                                Text(selected.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(question.header)
                    }
                }
            }
            .navigationTitle("Input required")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit(encodedAnswers)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func answerField(question: RemoteUserInputPrompt.Question, text: Binding<String>) -> some View {
        if question.isSecret {
            SecureField("Answer", text: text)
                .textInputAutocapitalization(.never)
        } else {
            TextField("Answer", text: text, axis: .vertical)
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id] ?? "" },
            set: { answers[id] = $0 }
        )
    }

    private func otherBinding(for id: String) -> Binding<String> {
        Binding(
            get: { otherAnswers[id] ?? "" },
            set: { otherAnswers[id] = $0 }
        )
    }

    private var encodedAnswers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: prompt.questions.map { question in
            let value = answers[question.id] == Self.otherValue
                ? (otherAnswers[question.id] ?? "")
                : (answers[question.id] ?? "")
            return (question.id, [value])
        })
    }

    private var canSubmit: Bool {
        prompt.questions.allSatisfy { question in
            let value = answers[question.id] == Self.otherValue
                ? (otherAnswers[question.id] ?? "")
                : (answers[question.id] ?? "")
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private struct RemoteMcpElicitationSheet: View {
    private enum Draft: Equatable {
        case unset
        case text(String)
        case boolean(Bool)
        case single(String)
        case multi(Set<String>)
    }

    let prompt: RemoteMcpElicitationPrompt
    let onSubmit: ([String: RemoteMcpElicitationValue]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: Draft]

    init(
        prompt: RemoteMcpElicitationPrompt,
        onSubmit: @escaping ([String: RemoteMcpElicitationValue]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _drafts = State(initialValue: Dictionary(uniqueKeysWithValues: prompt.fields.map { field in
            (field.key, Self.initialDraft(for: field))
        }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt.message)
                    Text(prompt.serverName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(prompt.fields, id: \.key) { field in
                    fieldSection(field)
                }
            }
            .navigationTitle("Input required")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit(encodedValues)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("mcpElicitationSubmit")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .accessibilityIdentifier("mcpElicitationForm")
    }

    @ViewBuilder
    private func fieldSection(_ field: RemoteMcpElicitationPrompt.Field) -> some View {
        Section {
            fieldControl(field)
            if let detail = validationDetail(for: field) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isValid(field) ? Color.secondary : Color.red)
            } else if let description = field.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 5) {
                Text(field.title)
                if field.required {
                    Text("Required")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldControl(_ field: RemoteMcpElicitationPrompt.Field) -> some View {
        switch field.kind {
        case .string(let format, _, _):
            TextField(field.title, text: textBinding(for: field.key), axis: .vertical)
                .textInputAutocapitalization(format == "email" || format == "uri" ? .never : .sentences)
                .autocorrectionDisabled(format == "email" || format == "uri")
                .keyboardType(format == "email" ? .emailAddress : format == "uri" ? .URL : .default)
                .accessibilityIdentifier("mcpField.\(field.key)")
            if !field.required, isSet(field.key) {
                Button("Clear value") { drafts[field.key] = .unset }
                    .font(.caption)
            }

        case .number(let integer, _, _):
            TextField(integer ? "Integer" : "Number", text: textBinding(for: field.key))
                .keyboardType(integer ? .numbersAndPunctuation : .decimalPad)
                .accessibilityIdentifier("mcpField.\(field.key)")
            if !field.required, isSet(field.key) {
                Button("Clear value") { drafts[field.key] = .unset }
                    .font(.caption)
            }

        case .boolean:
            Picker(field.title, selection: optionalBooleanBinding(for: field)) {
                if !field.required { Text("Not set").tag(Optional<Bool>.none) }
                Text("Yes").tag(Optional(true))
                Text("No").tag(Optional(false))
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mcpField.\(field.key)")

        case .singleSelect(let choices):
            Picker(field.title, selection: optionalSingleBinding(for: field)) {
                if !field.required { Text("Not set").tag(Optional<String>.none) }
                ForEach(choices) { choice in
                    Text(choice.label).tag(Optional(choice.value))
                }
            }
            .accessibilityIdentifier("mcpField.\(field.key)")

        case .multiSelect(let choices, _, let maxItems):
            ForEach(choices) { choice in
                Button {
                    toggleMulti(choice.value, field: field, maximum: maxItems)
                } label: {
                    HStack {
                        Text(choice.label)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedValues(for: field.key).contains(choice.value) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if !field.required, isSet(field.key) {
                Button("Clear selection") { drafts[field.key] = .unset }
                    .font(.caption)
            }
        }
    }

    private func textBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if case .text(let value) = drafts[key] { return value }
                return ""
            },
            set: { drafts[key] = .text($0) }
        )
    }

    private func optionalBooleanBinding(for field: RemoteMcpElicitationPrompt.Field) -> Binding<Bool?> {
        Binding(
            get: {
                if case .boolean(let value) = drafts[field.key] { return value }
                return nil
            },
            set: { value in
                drafts[field.key] = value.map(Draft.boolean) ?? .unset
            }
        )
    }

    private func optionalSingleBinding(for field: RemoteMcpElicitationPrompt.Field) -> Binding<String?> {
        Binding(
            get: {
                if case .single(let value) = drafts[field.key] { return value }
                return nil
            },
            set: { value in
                drafts[field.key] = value.map(Draft.single) ?? .unset
            }
        )
    }

    private func selectedValues(for key: String) -> Set<String> {
        if case .multi(let values) = drafts[key] { return values }
        return []
    }

    private func toggleMulti(
        _ value: String,
        field: RemoteMcpElicitationPrompt.Field,
        maximum: Int?
    ) {
        var values = selectedValues(for: field.key)
        if values.contains(value) {
            values.remove(value)
        } else if maximum.map({ values.count < $0 }) ?? true {
            values.insert(value)
        }
        drafts[field.key] = .multi(values)
    }

    private func isSet(_ key: String) -> Bool {
        guard let draft = drafts[key] else { return false }
        if case .unset = draft { return false }
        return true
    }

    private func isValid(_ field: RemoteMcpElicitationPrompt.Field) -> Bool {
        guard let draft = drafts[field.key] else { return false }
        if case .unset = draft { return !field.required }

        switch (field.kind, draft) {
        case (.string(_, let minLength, let maxLength), .text(let value)):
            if let minLength, value.count < minLength { return false }
            if let maxLength, value.count > maxLength { return false }
            return true

        case (.number(let integer, let minimum, let maximum), .text(let value)):
            guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            if integer, number.rounded() != number { return false }
            if let minimum, number < minimum { return false }
            if let maximum, number > maximum { return false }
            return true

        case (.boolean, .boolean):
            return true

        case (.singleSelect(let choices), .single(let value)):
            return choices.contains(where: { $0.value == value })

        case (.multiSelect(let choices, let minItems, let maxItems), .multi(let values)):
            guard values.allSatisfy({ value in choices.contains(where: { $0.value == value }) }) else { return false }
            if let minItems, values.count < minItems { return false }
            if let maxItems, values.count > maxItems { return false }
            return true

        default:
            return false
        }
    }

    private func validationDetail(for field: RemoteMcpElicitationPrompt.Field) -> String? {
        switch field.kind {
        case .string(_, let minLength, let maxLength):
            if let minLength, let maxLength { return "\(minLength)–\(maxLength) characters" }
            if let minLength { return "At least \(minLength) characters" }
            if let maxLength { return "At most \(maxLength) characters" }
        case .number(let integer, let minimum, let maximum):
            var parts: [String] = []
            if integer { parts.append("Whole number") }
            if let minimum { parts.append("min \(formatNumber(minimum))") }
            if let maximum { parts.append("max \(formatNumber(maximum))") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .multiSelect(_, let minItems, let maxItems):
            if let minItems, let maxItems { return "Choose \(minItems)–\(maxItems)" }
            if let minItems { return "Choose at least \(minItems)" }
            if let maxItems { return "Choose at most \(maxItems)" }
        case .boolean, .singleSelect:
            break
        }
        return nil
    }

    private var canSubmit: Bool {
        prompt.fields.allSatisfy(isValid)
    }

    private var encodedValues: [String: RemoteMcpElicitationValue] {
        Dictionary(uniqueKeysWithValues: prompt.fields.compactMap { field in
            guard let draft = drafts[field.key], isValid(field) else { return nil }
            switch (field.kind, draft) {
            case (.string, .text(let value)):
                return (field.key, .string(value))
            case (.number(let integer, _, _), .text(let value)):
                guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
                return integer
                    ? (field.key, .integer(Int(number)))
                    : (field.key, .number(number))
            case (.boolean, .boolean(let value)):
                return (field.key, .boolean(value))
            case (.singleSelect, .single(let value)):
                return (field.key, .string(value))
            case (.multiSelect, .multi(let values)):
                return (field.key, .strings(values.sorted()))
            default:
                return nil
            }
        })
    }

    private static func initialDraft(for field: RemoteMcpElicitationPrompt.Field) -> Draft {
        if let value = field.defaultValue {
            switch value {
            case .string(let value): return field.kind.isSingleSelect ? .single(value) : .text(value)
            case .number(let value): return .text(formatNumber(value))
            case .integer(let value): return .text(String(value))
            case .boolean(let value): return .boolean(value)
            case .strings(let values): return .multi(Set(values))
            }
        }

        switch field.kind {
        case .string:
            return field.required ? .text("") : .unset
        case .number, .boolean, .singleSelect:
            return .unset
        case .multiSelect:
            return field.required ? .multi([]) : .unset
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func formatNumber(_ value: Double) -> String {
        Self.formatNumber(value)
    }
}

private extension RemoteMcpElicitationPrompt.FieldKind {
    var isSingleSelect: Bool {
        if case .singleSelect = self { return true }
        return false
    }
}

#if DEBUG
struct RemoteMcpElicitationTestHarness: View {
    @State private var submitted = false
    @State private var cancelled = false

    private let prompt = RemoteMcpElicitationPrompt(params: [
        "serverName": "test-mcp",
        "threadId": "test-thread",
        "mode": "form",
        "message": "Configure the test deployment",
        "requestedSchema": [
            "type": "object",
            "required": ["name", "retries", "enabled", "region", "features"],
            "properties": [
                "name": [
                    "type": "string",
                    "title": "Name",
                    "minLength": 2,
                    "maxLength": 40
                ],
                "retries": [
                    "type": "integer",
                    "title": "Retries",
                    "minimum": 1,
                    "maximum": 5,
                    "default": 3
                ],
                "enabled": [
                    "type": "boolean",
                    "title": "Enabled",
                    "default": true
                ],
                "region": [
                    "type": "string",
                    "title": "Region",
                    "enum": ["kr", "us"],
                    "enumNames": ["Korea", "United States"],
                    "default": "kr"
                ],
                "features": [
                    "type": "array",
                    "title": "Features",
                    "items": ["type": "string", "enum": ["logs", "metrics"]],
                    "minItems": 1,
                    "maxItems": 2,
                    "default": ["logs"]
                ]
            ]
        ]
    ])!

    var body: some View {
        if submitted {
            Text("MCP_FORM_SUBMITTED")
        } else if cancelled {
            Text("MCP_FORM_CANCELLED")
        } else {
            RemoteMcpElicitationSheet(
                prompt: prompt,
                onSubmit: { _ in submitted = true },
                onCancel: { cancelled = true }
            )
        }
    }
}
#endif
