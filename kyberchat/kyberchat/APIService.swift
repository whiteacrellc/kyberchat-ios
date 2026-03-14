import Foundation

// MARK: - Response Models

struct LoginResponse: Decodable {
    let message: String
    let user: UserData?
    let token: String?
}

struct CreateUserResponse: Decodable {
    let message: String
    let user_uuid: String
    let token: String
}

struct UserData: Decodable {
    let user_uuid: String
    let username: String
    let registration_id: Int?
}

struct CreateUserRequest: Encodable {
    let user_uuid: String
    let username: String
    let identity_key_public: String
    let registration_id: Int
    let password: String
    /// ML-KEM-768 public key, hex-encoded (1184 bytes → 2368 hex chars). `nil` for pre-PQC clients.
    let kem_public_key: String?
}

struct Friend: Decodable, Identifiable {
    var id: String { user_uuid }
    let user_uuid: String
    let username: String
    let identity_key_public: String
    let registration_id: Int
    let is_online: Bool
}

struct FriendsResponse: Decodable {
    let friends: [Friend]
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case serverError(String)
    case invalidCredentials
    case usernameTaken
    case unauthorized        // 401 — session expired, route to login
    case rateLimited         // 429
    case notFound            // 404

    var errorDescription: String? {
        switch self {
        case .invalidResponse:      return "Invalid server response."
        case .serverError(let msg): return msg
        case .invalidCredentials:   return "Invalid username or password."
        case .usernameTaken:        return "That username is already taken."
        case .unauthorized:         return "Session expired. Please log in again."
        case .rateLimited:          return "Too many requests. Please try again later."
        case .notFound:             return "Not found."
        }
    }
}

// MARK: - Service

/// Thread-safe API client. All methods are `async throws`.
/// PASETO tokens are opaque strings — they are never decoded client-side.
/// A 401 response throws `APIError.unauthorized`, which `SessionManager.logout()` handles.
actor APIService {
    static let shared = APIService()

    private let baseURL = "https://quantchat-server-1078066473760.us-central1.run.app"
    private let timeout: TimeInterval = 15

    // MARK: - Auth

    /// Validates login, returns the PASETO token and user info.
    func validateLogin(username: String, password: String) async throws -> (token: String, user: UserData) {
        let body: [String: String] = ["username": username, "password": password]
        let (data, http) = try await post("/validate_login", body: body)

        if http.statusCode == 401 { throw APIError.invalidCredentials }
        try assertSuccess(http, data)

        let result = try decode(LoginResponse.self, from: data)
        guard let token = result.token, let user = result.user else { throw APIError.invalidResponse }
        return (token, user)
    }

    /// Registers a new user. Returns the PASETO token issued at registration
    /// so that key upload can proceed immediately without a second round-trip.
    ///
    /// - Parameter kemPublicKeyHex: Optional ML-KEM-768 public key (hex). Pass `nil` until
    ///   swift-crypto 3.3+ SPM dependency is added. Once present, always pass.
    func createUser(
        uuid: String,
        username: String,
        identityKeyPublic: String,
        registrationId: Int,
        password: String,
        kemPublicKeyHex: String? = nil
    ) async throws -> (token: String, userUUID: String) {
        let body = CreateUserRequest(
            user_uuid: uuid,
            username: username,
            identity_key_public: identityKeyPublic,
            registration_id: registrationId,
            password: password,
            kem_public_key: kemPublicKeyHex
        )
        let (data, http) = try await postEncodable("/create_user", body: body)
        if http.statusCode == 409 { throw APIError.usernameTaken }
        try assertSuccess(http, data, expected: 201)

        let result = try decode(CreateUserResponse.self, from: data)
        return (result.token, result.user_uuid)
    }

    // MARK: - Firebase Auth bridge (Option A)

    /// Exchanges the KyberChat PASETO session token for a Firebase custom token.
    ///
    /// The returned `firebase_token` should be passed to
    /// `Auth.auth().signIn(withCustomToken:)` (FirebaseAuth SDK) to establish
    /// a Firebase session. That session allows direct Firestore writes with proper
    /// security rule enforcement (`request.auth.uid == user_uuid`).
    ///
    /// Called by `FirebaseAuthService.refreshIfNeeded(pasteToken:)` — do not call directly.
    func getFirebaseToken(token: String) async throws -> FirebaseTokenResponse {
        let (data, http) = try await post("/firebase_token", body: EmptyBody(), token: token)
        try handleUnauthorized(http)
        if http.statusCode == 503 {
            throw APIError.serverError("Firebase authentication service is not available.")
        }
        try assertSuccess(http, data)
        return try decode(FirebaseTokenResponse.self, from: data)
    }

    // MARK: - Heartbeat

    func updateAuth(token: String) async throws {
        let (data, http) = try await post("/update_auth", body: EmptyBody(), token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data)
    }

    // MARK: - Keys

    func uploadKeyBundle(
        signedPreKey: SignedPreKeyUpload,
        oneTimePreKeys: [OTPKUpload],
        identityKeyEd25519Hex: String?,
        token: String
    ) async throws {
        var bodyDict: [String: Any] = [
            "signed_pre_key": [
                "key_id": signedPreKey.keyId,
                "public_key": signedPreKey.publicKeyHex,
                "signature": signedPreKey.signatureHex
            ],
            "one_time_pre_keys": oneTimePreKeys.map { ["key_id": $0.keyId, "public_key": $0.publicKeyHex] }
        ]
        if let ed25519Hex = identityKeyEd25519Hex {
            bodyDict["identity_key_ed25519_public"] = ed25519Hex
        }

        let (data, http) = try await postJSON("/keys/upload", body: bodyDict, token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data, expected: 201)
    }

    func fetchKeyBundle(targetUUID: String, token: String) async throws -> KeyBundle {
        let (data, http) = try await get("/keys/bundle/\(targetUUID)", token: token)
        try handleUnauthorized(http)
        if http.statusCode == 404 { throw APIError.notFound }
        try assertSuccess(http, data)
        return try decode(KeyBundle.self, from: data)
    }

    func replenishKeys(oneTimePreKeys: [OTPKUpload], token: String) async throws {
        let body: [String: Any] = [
            "one_time_pre_keys": oneTimePreKeys.map { ["key_id": $0.keyId, "public_key": $0.publicKeyHex] }
        ]
        let (data, http) = try await postJSON("/keys/replenish", body: body, token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data, expected: 201)
    }

    // MARK: - Friends

    func getFriends(token: String) async throws -> [Friend] {
        let (data, http) = try await post("/get_friends", body: EmptyBody(), token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data)
        return try decode(FriendsResponse.self, from: data).friends
    }

    func sendFriendRequest(username: String, token: String) async throws -> String {
        let (data, http) = try await post("/friends/request", body: ["username": username], token: token)
        try handleUnauthorized(http)
        if http.statusCode == 429 { throw APIError.rateLimited }
        if http.statusCode == 404 { throw APIError.notFound }
        try assertSuccess(http, data, expected: [200, 201])
        let result = try decode([String: String].self, from: data)
        return result["status"] ?? "pending"
    }

    func acceptFriendRequest(requesterUUID: String, token: String) async throws {
        let (data, http) = try await post("/friends/accept", body: ["requester_uuid": requesterUUID], token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data)
    }

    func removeFriend(friendUUID: String, token: String) async throws {
        let (data, http) = try await post("/friends/remove", body: ["friend_uuid": friendUUID], token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data)
    }

    // MARK: - Search

    func searchUser(username: String, token: String) async throws -> SearchResult {
        let (data, http) = try await post("/search_user", body: ["username": username], token: token)
        try handleUnauthorized(http)
        if http.statusCode == 429 { throw APIError.rateLimited }
        if http.statusCode == 404 { throw APIError.notFound }
        try assertSuccess(http, data)
        return try decode(SearchResult.self, from: data)
    }

    // MARK: - Messages

    func sendMessage(recipientUUID: String, ciphertextBase64: String, token: String) async throws -> String {
        let body = ["recipient_uuid": recipientUUID, "ciphertext": ciphertextBase64]
        let (data, http) = try await post("/messages/send", body: body, token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data, expected: 201)
        let result = try decode([String: String].self, from: data)
        return result["message_id"] ?? ""
    }

    func getMessages(token: String) async throws -> [IncomingMessage] {
        let (data, http) = try await get("/messages", token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data)
        return try decode(MessagesResponse.self, from: data).messages
    }

    func ackMessages(messageIDs: [String], token: String) async throws {
        let body: [String: Any] = ["message_ids": messageIDs]
        let (data, http) = try await postJSON("/messages/ack", body: body, token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data)
    }

    // MARK: - Device registration

    func registerDevice(pushToken: String, token: String) async throws {
        let (data, http) = try await post("/register_device", body: ["push_token": pushToken], token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data, expected: [200, 201])
    }

    func unregisterDevice(pushToken: String, token: String) async throws {
        let (data, http) = try await post("/unregister_device", body: ["push_token": pushToken], token: token)
        try handleUnauthorized(http)
        try assertSuccess(http, data)
    }

    // MARK: - Password

    func changePassword(oldPassword: String, newPassword: String, token: String) async throws {
        let body = ["old_password": oldPassword, "new_password": newPassword]
        let (data, http) = try await post("/change_password", body: body, token: token)
        try handleUnauthorized(http)
        if http.statusCode == 401 { throw APIError.serverError("Current password is incorrect.") }
        try assertSuccess(http, data)
    }

    func deleteAccount(password: String, token: String) async throws {
        let (data, http) = try await post("/delete_user", body: ["password": password], token: token)
        try handleUnauthorized(http)
        if http.statusCode == 401 { throw APIError.serverError("Password is incorrect.") }
        try assertSuccess(http, data)
    }

    // MARK: - HTTP primitives

    private func buildRequest(_ path: String, method: String, token: String? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL + path)!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = token {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func get(_ path: String, token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = buildRequest(path, method: "GET", token: token)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }

    private func post<T: Encodable>(_ path: String, body: T, token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = buildRequest(path, method: "POST", token: token)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }

    private func postEncodable<T: Encodable>(_ path: String, body: T, token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        try await post(path, body: body, token: token)
    }

    private func postJSON(_ path: String, body: [String: Any], token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = buildRequest(path, method: "POST", token: token)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }

    private func assertSuccess(_ http: HTTPURLResponse, _ data: Data, expected: Int = 200) throws {
        guard http.statusCode == expected else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.serverError(msg ?? "Unexpected error (HTTP \(http.statusCode)).")
        }
    }

    private func assertSuccess(_ http: HTTPURLResponse, _ data: Data, expected: [Int]) throws {
        guard expected.contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.serverError(msg ?? "Unexpected error (HTTP \(http.statusCode)).")
        }
    }

    private func handleUnauthorized(_ http: HTTPURLResponse) throws {
        if http.statusCode == 401 {
            // Signal the app to clear session and re-route to login
            Task { @MainActor in SessionManager.shared.logout() }
            throw APIError.unauthorized
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}

// MARK: - Supporting types

struct EmptyBody: Encodable {}

struct SignedPreKeyUpload {
    let keyId: Int
    let publicKeyHex: String
    let signatureHex: String
}

struct OTPKUpload {
    let keyId: Int
    let publicKeyHex: String
}

struct KeyBundle: Decodable {
    let user_uuid: String
    let identity_key_public: String
    let registration_id: Int
    let signed_pre_key: SPKBundle
    let one_time_pre_key: OTPKBundle?
    let otpk_remaining: Int
    /// ML-KEM-768 public key, hex-encoded (1184 bytes). `nil` for pre-PQC accounts.
    /// Used as the `kem_pk` input for the hybrid X3DH KEM encapsulation step.
    let kem_public_key: String?
}

struct SPKBundle: Decodable {
    let key_id: Int
    let public_key: String
    let signature: String
}

struct OTPKBundle: Decodable {
    let key_id: Int
    let public_key: String
}

struct SearchResult: Decodable {
    let user_uuid: String?
    let username: String?
    let `private`: Int?
    let status: String?
}

struct IncomingMessage: Decodable, Identifiable {
    var id: String { message_id }
    let message_id: String
    let sender_uuid: String
    let ciphertext: String
    let created_at: String
}

struct MessagesResponse: Decodable {
    let messages: [IncomingMessage]
}

struct FirebaseTokenResponse: Decodable {
    /// Firebase custom token — pass to Auth.auth().signIn(withCustomToken:)
    let firebase_token: String
    /// The Firebase UID assigned to this session (equals the KyberChat user_uuid)
    let uid: String
    /// Lifetime of the custom token itself in seconds (always 3600 — Firebase maximum).
    /// The SDK-derived ID token auto-refreshes; this is informational only.
    let expires_in: Int
    /// Unix timestamp of when this token was issued (server clock).
    let issued_at: Int
}
