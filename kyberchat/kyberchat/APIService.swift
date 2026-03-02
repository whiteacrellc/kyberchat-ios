import Foundation

// MARK: - Response Models

struct LoginResponse: Decodable {
    let message: String
    let user: UserData?
}

struct UserData: Decodable {
    let user_uuid: String
    let username: String
}

struct CreateUserRequest: Encodable {
    let user_uuid: String
    let username: String
    let identity_key_public: String
    let registration_id: Int
    let password: String
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case serverError(String)
    case invalidCredentials
    case usernameTaken

    var errorDescription: String? {
        switch self {
        case .invalidResponse:          return "Invalid server response."
        case .serverError(let msg):     return msg
        case .invalidCredentials:       return "Invalid username or password."
        case .usernameTaken:            return "That username is already taken."
        }
    }
}

// MARK: - Service

actor APIService {
    static let shared = APIService()

    private let baseURL = "https://quantchat-server-1078066473760.us-central1.run.app"

    /// Validates a login by checking username and password.
    /// Throws `APIError.invalidCredentials` if either is wrong or the account is deleted.
    func validateLogin(username: String, password: String) async throws -> UserData {
        let url = URL(string: "\(baseURL)/validate_login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "username": username,
            "password": password
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if http.statusCode == 401 {
            throw APIError.invalidCredentials
        }

        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.serverError(msg ?? "Unexpected error (HTTP \(http.statusCode)).")
        }

        let result = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard let user = result.user else { throw APIError.invalidResponse }
        return user
    }

    /// Registers a new user. Throws `APIError.usernameTaken` on conflict.
    func createUser(
        uuid: String,
        username: String,
        identityKeyPublic: String,
        registrationId: Int,
        password: String
    ) async throws {
        let url = URL(string: "\(baseURL)/create_user")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateUserRequest(
            user_uuid: uuid,
            username: username,
            identity_key_public: identityKeyPublic,
            registration_id: registrationId,
            password: password
        ))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if http.statusCode == 409 {
            throw APIError.usernameTaken
        }

        guard http.statusCode == 201 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.serverError(msg ?? "Unexpected error (HTTP \(http.statusCode)).")
        }
    }
}
