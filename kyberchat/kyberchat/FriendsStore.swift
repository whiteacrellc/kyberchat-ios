import Foundation

// MARK: - FriendsStore
//
// Single source of truth for the friends list and friend-request state.
// Injected into FriendsListView via @Environment and shared with any
// child view that needs to read or mutate the friends list.

@Observable
final class FriendsStore {

    // MARK: - Published state

    var friends:      [Friend] = []
    var isLoading:    Bool     = false
    var errorMessage: String?

    // MARK: - Internal helpers

    private var token: String { SessionManager.shared.token ?? "" }

    // MARK: - Data loading

    /// Fetches the full accepted-friends list. Safe to call on any task.
    func loadFriends() async {
        guard !token.isEmpty else { return }
        isLoading    = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            friends = try await APIService.shared.getFriends(token: token)
        } catch APIError.unauthorized {
            // SessionManager.logout() was already called inside APIService.
            // Navigation back to login is handled by ContentView observing
            // SessionManager.isLoggedIn — nothing more to do here.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mutations

    /// Removes an accepted friendship. Updates the local list optimistically.
    /// Throws on network error so the caller can show UI feedback.
    func removeFriend(uuid: String) async throws {
        guard !token.isEmpty else { return }
        try await APIService.shared.removeFriend(friendUUID: uuid, token: token)
        friends.removeAll { $0.user_uuid == uuid }
    }

    /// Sends a friend request by username. Returns the relationship status string.
    func sendFriendRequest(username: String) async throws -> String {
        guard !token.isEmpty else { return "" }
        return try await APIService.shared.sendFriendRequest(username: username, token: token)
    }

    /// Accepts a pending friend request. Reloads the list on success.
    func acceptFriendRequest(requesterUUID: String) async throws {
        guard !token.isEmpty else { return }
        try await APIService.shared.acceptFriendRequest(requesterUUID: requesterUUID, token: token)
        await loadFriends()
    }
}
