import SwiftUI
import CryptoKit

struct CreateAccountView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showPasswordRulesAlert = false

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !isLoading
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo — matches the LoginView header
            VStack(spacing: 0) {
                Image("KyberChatLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .padding(.bottom, 16)

                Text("Create Account")
                    .font(.title)
                    .bold()
                Text("Choose a username and password.\nNo email or phone number required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                PasswordFieldView(placeholder: "Password", text: $password)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await createAccount() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Create Account")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }

            Spacer()
        }
        .padding(.horizontal, 32)
        .navigationTitle("New Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Password Requirements", isPresented: $showPasswordRulesAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("""
                Your password must:
                • Be longer than 6 characters
                • Contain at least one uppercase letter (A–Z)
                • Contain at least one lowercase letter (a–z)
                • Contain at least one number (0–9)
                • Contain at least one special character (e.g. !@#$%^&*)
                """)
        }
    }

    // MARK: - Validation

    private func isValidPassword(_ pw: String) -> Bool {
        guard pw.count > 6 else { return false }
        let hasUpper   = pw.range(of: "[A-Z]",       options: .regularExpression) != nil
        let hasLower   = pw.range(of: "[a-z]",       options: .regularExpression) != nil
        let hasDigit   = pw.range(of: "[0-9]",       options: .regularExpression) != nil
        let hasSpecial = pw.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
        return hasUpper && hasLower && hasDigit && hasSpecial
    }

    // MARK: - Actions

    private func createAccount() async {
        errorMessage = nil

        guard isValidPassword(password) else {
            password = ""               // Clear the field
            showPasswordRulesAlert = true
            return
        }

        isLoading = true
        defer { isLoading = false }

        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let uuid = UUID().uuidString
        let registrationId = Int.random(in: 1...65535)
        let identityKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyHex = identityKey.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }
            .joined()

        do {
            try await APIService.shared.createUser(
                uuid: uuid,
                username: trimmedUsername,
                identityKeyPublic: publicKeyHex,
                registrationId: registrationId,
                password: password
            )
            dismiss()
        } catch APIError.usernameTaken {
            errorMessage = "That username is already taken. Please choose another."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
