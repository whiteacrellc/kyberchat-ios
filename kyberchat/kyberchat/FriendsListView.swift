import SwiftUI

// MARK: - FriendsListView (Screen 4)
//
// Main post-login screen. Shows the accepted friends list with online-status
// indicators. Drives the heartbeat timer (POST /update_auth every 90s) and
// listens for FCM-triggered refresh notifications posted by AppDelegate.
//
// Architecture:
//   FriendsListView
//     ├── FriendRow           (private) — single list cell
//     ├── SearchUserSheet     — find + add friends by username
//     │     └── SearchResultRow (private) — result cell with action button
//     └── SettingsView        — gear icon sheet → Change Password / Delete Account

struct FriendsListView: View {
    @Environment(SessionManager.self) private var session
    @State private var store           = FriendsStore()
    @State private var showSearch      = false
    @State private var showSettings    = false
    @State private var friendToRemove: Friend?
    @State private var showRemoveAlert = false
    @State private var heartbeatTask:  Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.friends.isEmpty {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if store.friends.isEmpty && !store.isLoading {
                    ContentUnavailableView {
                        Label("No friends yet", systemImage: "person.2.slash")
                    } description: {
                        Text("Tap the search icon to find someone to connect with.")
                    } actions: {
                        Button("Search") { showSearch = true }
                            .buttonStyle(.borderedProminent)
                    }

                } else {
                    List {
                        ForEach(store.friends) { friend in
                            NavigationLink(
                                destination: Text("Chat with \(friend.username) — coming soon")
                                    .navigationTitle(friend.username)
                            ) {
                                FriendRow(friend: friend)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    friendToRemove = friend
                                    showRemoveAlert = true
                                } label: {
                                    Label("Remove", systemImage: "person.fill.xmark")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("KyberChat")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search for friends")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable {
                await store.loadFriends()
            }
            // Remove-friend confirmation
            .alert("Remove Friend?",
                   isPresented: $showRemoveAlert,
                   presenting: friendToRemove
            ) { friend in
                Button("Remove \(friend.username)", role: .destructive) {
                    Task {
                        do {
                            try await store.removeFriend(uuid: friend.user_uuid)
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) { friendToRemove = nil }
            } message: { friend in
                Text("You will no longer be able to message \(friend.username). You can send a new friend request at any time.")
            }
            // Error toast
            .alert("Error", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchUserSheet()
                .environment(session)
                .onDisappear {
                    // Re-load in case a request was accepted while the sheet was open
                    Task { await store.loadFriends() }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(session)
        }
        .task {
            // Ensure Firebase Auth session exists for direct Firestore writes.
            // refreshIfNeeded() is a no-op when Firebase already has a valid user.
            if let token = session.token {
                await FirebaseAuthService.shared.refreshIfNeeded(pasteToken: token)
            }
            await store.loadFriends()
            startHeartbeat()
        }
        // FCM-triggered refresh: AppDelegate posts these notifications when a
        // silent push arrives. Register once per view lifetime.
        .onReceive(NotificationCenter.default.publisher(for: .kycRefreshFriends)) { _ in
            Task { await store.loadFriends() }
        }
        .onDisappear {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            // First ping after 90 seconds; loop until the view disappears.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { break }
                guard let token = session.token else { break }
                try? await APIService.shared.updateAuth(token: token)
            }
        }
    }
}

// MARK: - FCM Notification Names

extension Notification.Name {
    /// Posted by AppDelegate when an FCM push with type FRIEND_REQUEST,
    /// FRIEND_REQUEST_ACCEPTED, or NEW_MESSAGE is received. FriendsListView
    /// observes this to refresh the list without polling.
    static let kycRefreshFriends = Notification.Name("kycRefreshFriends")
}

// MARK: - FriendRow

private struct FriendRow: View {
    let friend: Friend

    var body: some View {
        HStack(spacing: 12) {
            // Avatar: initials placeholder until user-uploaded avatars are supported
            Circle()
                .fill(avatarColor)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(friend.username.prefix(1).uppercased())
                        .font(.headline)
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(friend.username)
                    .font(.headline)
                Text(friend.is_online ? "Online" : "Offline")
                    .font(.caption)
                    .foregroundStyle(friend.is_online ? .green : .secondary)
            }

            Spacer()

            Circle()
                .fill(friend.is_online ? Color.green : Color(.systemGray4))
                .frame(width: 10, height: 10)
        }
        .padding(.vertical, 4)
    }

    // Deterministic colour from username so the same user always gets the same avatar tint
    private var avatarColor: Color {
        let colours: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .cyan]
        let index = abs(friend.username.hashValue) % colours.count
        return colours[index]
    }
}

// MARK: - SearchUserSheet

struct SearchUserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session

    @State private var username       = ""
    @State private var searchResult:  SearchResult?
    @State private var isSearching    = false
    @State private var errorMessage:  String?
    @State private var successMessage: String?
    @State private var actionInFlight = false
    @State private var searchTask:    Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {

                // ── Search field ──────────────────────────────────────────
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search by username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { triggerSearch() }
                    if isSearching {
                        ProgressView()
                            .transition(.opacity)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)

                // ── Feedback messages ─────────────────────────────────────
                if let error = errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .transition(.opacity)
                }

                if let msg = successMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(msg)
                            .foregroundStyle(.green)
                    }
                    .font(.callout)
                    .padding(.horizontal)
                    .transition(.opacity)
                }

                // ── Result ────────────────────────────────────────────────
                if let result = searchResult {
                    SearchResultRow(
                        result: result,
                        actionInFlight: $actionInFlight
                    ) {
                        Task { await sendFriendRequest(to: result) }
                    }
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()
            }
            .padding(.top)
            .animation(.easeInOut(duration: 0.2), value: searchResult?.user_uuid)
            .animation(.easeInOut(duration: 0.15), value: errorMessage)
            .animation(.easeInOut(duration: 0.15), value: successMessage)
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Debounced search: fires 500 ms after the user stops typing
            .onChange(of: username) { _, newValue in
                searchTask?.cancel()
                searchResult   = nil
                errorMessage   = nil
                successMessage = nil
                let query = newValue.trimmingCharacters(in: .whitespaces)
                guard query.count >= 2 else { return }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await performSearch(query: query)
                }
            }
        }
    }

    // MARK: - Actions

    private func triggerSearch() {
        searchTask?.cancel()
        let query = username.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        Task { await performSearch(query: query) }
    }

    private func performSearch(query: String) async {
        guard let token = session.token else { return }
        isSearching  = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            searchResult = try await APIService.shared.searchUser(username: query, token: token)
        } catch APIError.notFound {
            errorMessage = "No user found with that username."
            searchResult = nil
        } catch APIError.rateLimited {
            errorMessage = "Too many searches. Please wait a moment."
            searchResult = nil
        } catch {
            errorMessage = error.localizedDescription
            searchResult = nil
        }
    }

    private func sendFriendRequest(to result: SearchResult) async {
        guard let token = session.token, let targetUsername = result.username else { return }
        actionInFlight = true
        errorMessage   = nil
        defer { actionInFlight = false }

        do {
            let status = try await APIService.shared.sendFriendRequest(
                username: targetUsername, token: token
            )
            switch status {
            case "accepted":
                successMessage = "You're already connected with \(targetUsername)!"
            case "pending":
                successMessage = "Friend request sent to \(targetUsername)."
            default:
                successMessage = "Request sent."
            }
            searchResult = nil
            username     = ""
        } catch APIError.rateLimited {
            errorMessage = "Too many requests. Please try again later."
        } catch APIError.notFound {
            errorMessage = "User not found."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - SearchResultRow

private struct SearchResultRow: View {
    let result:         SearchResult
    @Binding var actionInFlight: Bool
    let onAdd:          () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.title)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.username ?? "Unknown")
                    .font(.headline)
                statusText
            }

            Spacer()
            actionButton
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusText: some View {
        if result.status == "accepted" {
            Text("Already connected")
                .font(.caption).foregroundStyle(.green)
        } else if result.status == "pending" {
            Text("Request pending")
                .font(.caption).foregroundStyle(.orange)
        } else if (result.`private` ?? 0) == 1 {
            Text("Private account — they will be notified")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("KyberChat user")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if result.status == "accepted" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)

        } else if result.status == "pending" {
            Text("Pending")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())

        } else {
            Button {
                onAdd()
            } label: {
                if actionInFlight {
                    ProgressView()
                        .frame(width: 60)
                } else {
                    Text("Add")
                        .fontWeight(.semibold)
                        .frame(width: 60)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(actionInFlight)
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(\.dismiss)    private var dismiss
    @Environment(SessionManager.self) private var session

    @State private var showChangePassword    = false
    @State private var showDeleteAccountAlert = false
    @State private var deletePassword        = ""
    @State private var isDeleting            = false
    @State private var deleteError:          String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Button("Change Password") {
                        showChangePassword = true
                    }

                    Button(role: .destructive) {
                        showDeleteAccountAlert = true
                    } label: {
                        Label("Delete Account", systemImage: "trash")
                    }
                }

                Section("Session") {
                    Button(role: .destructive) {
                        Task { await logout() }
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section {
                    HStack {
                        Text("Logged in as")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(session.username ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showChangePassword) {
                ChangePasswordView()
                    .environment(session)
            }
            .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
                SecureField("Enter your password", text: $deletePassword)
                Button("Delete", role: .destructive) {
                    Task { await deleteAccount() }
                }
                .disabled(deletePassword.isEmpty || isDeleting)
                Button("Cancel", role: .cancel) {
                    deletePassword = ""
                    deleteError    = nil
                }
            } message: {
                Text(deleteError ?? "This action is permanent and cannot be undone. Your account, identity keys, and all messages will be deleted.")
            }
        }
    }

    private func logout() async {
        guard let token = session.token else {
            session.logout()
            return
        }
        // Best-effort: unregister device token before clearing session.
        // FCM token retrieval is handled by AppDelegate; here we just clear state.
        session.logout()
        dismiss()
        _ = try? await APIService.shared.updateAuth(token: token) // final heartbeat
    }

    private func deleteAccount() async {
        guard let token = session.token else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await APIService.shared.deleteAccount(password: deletePassword, token: token)
            session.logout()
            dismiss()
        } catch APIError.serverError(let msg) {
            deleteError    = msg
            deletePassword = ""
            // Re-present the alert on next interaction — SwiftUI re-presents on isPresented flip
            showDeleteAccountAlert = true
        } catch {
            deleteError    = error.localizedDescription
            deletePassword = ""
            showDeleteAccountAlert = true
        }
    }
}
