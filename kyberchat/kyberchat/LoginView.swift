import SwiftUI

struct LoginView: View {
    @Binding var isLoggedIn: Bool

    @State private var username = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 0) {
                Image("KyberChatLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .padding(.bottom, 75)

                Text("KyberChat")
                    .font(.largeTitle)
                    .bold()
                Text("Zero-knowledge encrypted messaging")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                    Task { await login() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Log In")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }

            NavigationLink("Create Account") {
                CreateAccountView()
            }
            .font(.subheadline)

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func login() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await APIService.shared.validateLogin(
                username: username.trimmingCharacters(in: .whitespaces)
            )
            isLoggedIn = true
        } catch APIError.userNotFound {
            errorMessage = "No account found for that username."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
