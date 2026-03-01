import SwiftUI
import CryptoKit

struct CreateAccountView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 8) {
                Text("Create Account")
                    .font(.title)
                    .bold()
                Text("Choose a username. No email or phone number required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

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
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }

            Spacer()
        }
        .padding(.horizontal, 32)
        .navigationTitle("New Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func createAccount() async {
        errorMessage = nil
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
                registrationId: registrationId
            )
            dismiss()
        } catch APIError.usernameTaken {
            errorMessage = "That username is already taken. Please choose another."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
