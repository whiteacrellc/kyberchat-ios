import SwiftUI

// MARK: - ChangePasswordView (Screen 3)
//
// Lets the authenticated user change their account password.
// Requires the current password (Argon2id-verified server-side) plus a new
// password that meets the same strength rules as account creation.
//
// Flow:
//   1. User enters current + new + confirm passwords
//   2. Client-side validation (strength check + match check)
//   3. POST /change_password — server verifies old_password and updates hash
//   4. Success alert → dismiss (existing PASETO token remains valid)
//
// Navigation entry point: SettingsView sheet (gear icon in FriendsListView toolbar)

struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session

    @State private var currentPassword  = ""
    @State private var newPassword      = ""
    @State private var confirmPassword  = ""
    @State private var isLoading        = false
    @State private var errorMessage:    String?
    @State private var showSuccess      = false
    @State private var showPasswordRulesAlert = false

    private var passwordsMatch: Bool { newPassword == confirmPassword }

    private var canSave: Bool {
        !currentPassword.isEmpty &&
        !newPassword.isEmpty &&
        !confirmPassword.isEmpty &&
        passwordsMatch &&
        !isLoading
    }

    var body: some View {
        NavigationStack {
            Form {

                // ── Current password ──────────────────────────────────────
                Section {
                    PasswordFieldView(placeholder: "Current password", text: $currentPassword)
                } header: {
                    Text("Current Password")
                }

                // ── New password ──────────────────────────────────────────
                Section {
                    PasswordFieldView(placeholder: "New password", text: $newPassword)
                    PasswordFieldView(placeholder: "Confirm new password", text: $confirmPassword)

                    if !confirmPassword.isEmpty && !passwordsMatch {
                        Label("Passwords do not match.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("New Password")
                } footer: {
                    Button {
                        showPasswordRulesAlert = true
                    } label: {
                        Label("View password requirements", systemImage: "info.circle")
                            .font(.caption)
                    }
                }

                // ── Error display ─────────────────────────────────────────
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await changePassword() }
                        }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                    }
                }
            }
            // ── Success ───────────────────────────────────────────────────
            .alert("Password Updated", isPresented: $showSuccess) {
                Button("OK") { dismiss() }
            } message: {
                Text("Your password has been changed successfully. Your existing session remains active.")
            }
            // ── Password rules ────────────────────────────────────────────
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
            .interactiveDismissDisabled(isLoading)
        }
    }

    // MARK: - Change password action

    private func changePassword() async {
        errorMessage = nil

        // Strength check before hitting the network
        guard isValidPassword(newPassword) else {
            errorMessage = "New password doesn't meet requirements. Tap the info button below for details."
            newPassword     = ""
            confirmPassword = ""
            return
        }

        guard let token = session.token else {
            errorMessage = "Session expired. Please log in again."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await APIService.shared.changePassword(
                oldPassword: currentPassword,
                newPassword: newPassword,
                token: token
            )
            showSuccess = true

        } catch APIError.serverError(let msg) {
            // "Current password is incorrect." comes from the server unchanged
            errorMessage    = msg
            currentPassword = ""    // force re-entry

        } catch APIError.unauthorized {
            // Token expired mid-flow — SessionManager already triggered logout
            errorMessage = "Session expired. Please log in again."

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Password validation
    //
    // Mirrors the same rules as CreateAccountView and the server's Argon2id policy.
    // Consider extracting to a shared PasswordValidator struct when a third screen
    // needs this logic.

    private func isValidPassword(_ pw: String) -> Bool {
        guard pw.count > 6 else { return false }
        let hasUpper   = pw.range(of: "[A-Z]",        options: .regularExpression) != nil
        let hasLower   = pw.range(of: "[a-z]",        options: .regularExpression) != nil
        let hasDigit   = pw.range(of: "[0-9]",        options: .regularExpression) != nil
        let hasSpecial = pw.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
        return hasUpper && hasLower && hasDigit && hasSpecial
    }
}
