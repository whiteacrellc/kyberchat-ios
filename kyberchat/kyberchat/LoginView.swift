import SwiftUI

struct LoginView: View {
    @Environment(SessionManager.self) private var session

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !isLoading
    }

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
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .onSubmit { focusPassword() }

                PasswordFieldView(placeholder: "Password", text: $password)

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
                            ProgressView().tint(.white)
                        } else {
                            Text("Log In")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)

                Button("Forgot password?") { }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .alert("Password Recovery", isPresented: .constant(false)) { } message: {
                        Text("Contact support to reset your password.")
                    }
            }

            NavigationLink("Create Account") {
                CreateAccountView()
            }
            .font(.subheadline)

            Spacer()
        }
        .padding(.horizontal, 32)
        .contentShape(Rectangle())
        .onTapGesture { hideKeyboard() }
    }

    // MARK: - Actions

    @State private var passwordFocused = false

    private func focusPassword() {
        // Focus is managed within PasswordFieldView; this triggers the next field
        passwordFocused = true
    }

    private func login() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let (token, user) = try await APIService.shared.validateLogin(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password
            )
            session.login(token: token, userUUID: user.user_uuid, username: user.username)
        } catch APIError.invalidCredentials {
            errorMessage = "Invalid username or password."
        } catch APIError.unauthorized {
            errorMessage = "Session expired. Please try again."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}
