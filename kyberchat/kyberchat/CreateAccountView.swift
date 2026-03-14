import SwiftUI
import CryptoKit

// MARK: - CreateAccountView
//
// Registration flow:
//   1. User enters username + password
//   2. We generate a BIP39 mnemonic and derive all keys from it
//   3. Show MnemonicRevealView — user MUST acknowledge responsibility
//   4. POST /create_user (with derived keys)
//   5. POST /keys/upload (with token from step 4)
//   6. Transition to HomeView via SessionManager

struct CreateAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session

    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showPasswordRulesAlert = false
    @State private var showMnemonicReveal = false
    @State private var pendingMnemonic: [String] = []

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !confirmPassword.isEmpty &&
        !isLoading
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

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
                    .textInputAutocapitalization(.never)

                PasswordFieldView(placeholder: "Password", text: $password)
                PasswordFieldView(placeholder: "Confirm Password", text: $confirmPassword)

                // Password mismatch warning
                if !confirmPassword.isEmpty && password != confirmPassword {
                    Text("Passwords do not match.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // General error
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await beginRegistration() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Create Account")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit || password != confirmPassword)
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
        .fullScreenCover(isPresented: $showMnemonicReveal) {
            MnemonicRevealView(mnemonic: pendingMnemonic) {
                // Confirmed — now register
                Task { await registerWithMnemonic(pendingMnemonic) }
            }
        }
    }

    // MARK: - Step 1: Validate → Generate mnemonic → Show reveal screen

    private func beginRegistration() async {
        errorMessage = nil

        guard isValidPassword(password) else {
            password = ""
            confirmPassword = ""
            showPasswordRulesAlert = true
            return
        }

        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let words = try MnemonicService.generateMnemonic()
            pendingMnemonic = words
            showMnemonicReveal = true
        } catch {
            errorMessage = "Failed to generate account keys. Please try again."
        }
    }

    // MARK: - Step 2: Derive keys, register, upload key bundle

    private func registerWithMnemonic(_ words: [String]) async {
        isLoading = true
        defer { isLoading = false }
        showMnemonicReveal = false

        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)

        do {
            // Derive master seed from mnemonic
            let seed = try MnemonicService.mnemonicToSeed(words)

            // Derive and persist identity material (master seed → all keys via HKDF)
            let identity = try MnemonicService.persistSeedAndDeriveIdentity(seed: seed)

            // Persist ML-KEM-768 seed to Keychain (re-derivable, cached for speed)
            KeychainHelper.save(identity.kemSeed, account: KeychainAccount.kemPrivateKeySeed.rawValue)

            // Derive ML-KEM-768 public key to send to the server.
            // Requires swift-crypto 3.3+ (MLKem768 via the "Crypto" SPM module).
            // If the SPM dep isn't added yet this will be a compile error — that's intentional.
            let kemPublicKeyHex = try MnemonicService.kemPublicKeyHex(from: identity.kemSeed)

            // Register with the server — get back a token immediately
            let (token, _) = try await APIService.shared.createUser(
                uuid: identity.userUUID,
                username: trimmedUsername,
                identityKeyPublic: identity.identityKeyPublicHex,
                registrationId: identity.registrationID,
                password: password,
                kemPublicKeyHex: kemPublicKeyHex
            )

            // Generate and upload pre-key bundle using the registration token
            let (spk, otpks) = generatePreKeys(signingKey: identity.signingKeyPriv)
            try await APIService.shared.uploadKeyBundle(
                signedPreKey: spk,
                oneTimePreKeys: otpks,
                identityKeyEd25519Hex: identity.signingKeyPriv.publicKey.rawRepresentation.hexString,
                token: token
            )

            // Establish session — navigate to HomeView
            session.login(token: token, userUUID: identity.userUUID, username: trimmedUsername)

        } catch APIError.usernameTaken {
            errorMessage = "That username is already taken. Please choose another."
            // Re-show the form (mnemonic is still valid, keys still pending)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pre-key generation

    /// Generates a Signed Pre-Key and 15 One-Time Pre-Keys.
    /// SPK is signed with the Ed25519 signing key.
    private func generatePreKeys(
        signingKey: Curve25519.Signing.PrivateKey
    ) -> (spk: SignedPreKeyUpload, otpks: [OTPKUpload]) {
        // Signed Pre-Key
        let spkPriv = Curve25519.KeyAgreement.PrivateKey()
        let spkPubBytes = spkPriv.publicKey.rawRepresentation
        let spkSig = (try? signingKey.signature(for: spkPubBytes)) ?? Data()
        let spkId = Int.random(in: 1...65535)

        // Store SPK private key for later use in X3DH
        KeychainHelper.save(spkPriv.rawRepresentation, account: KeychainAccount.signedPreKeyPrivate.rawValue)
        KeychainHelper.save(String(spkId), account: KeychainAccount.signedPreKeyId.rawValue)

        let spk = SignedPreKeyUpload(
            keyId: spkId,
            publicKeyHex: spkPubBytes.hexString,
            signatureHex: spkSig.hexString
        )

        // One-Time Pre-Keys (15 fresh keys)
        var otpks: [OTPKUpload] = []
        for i in 1...15 {
            let otpkPriv = Curve25519.KeyAgreement.PrivateKey()
            let otpkId = Int.random(in: 1...65535)
            // Store each OTPK private key — keyed by ID
            KeychainHelper.save(otpkPriv.rawRepresentation, account: "otpk_\(otpkId)")
            otpks.append(OTPKUpload(keyId: otpkId, publicKeyHex: otpkPriv.publicKey.rawRepresentation.hexString))
        }

        return (spk, otpks)
    }

    // MARK: - Password validation

    private func isValidPassword(_ pw: String) -> Bool {
        guard pw.count > 6 else { return false }
        let hasUpper   = pw.range(of: "[A-Z]",        options: .regularExpression) != nil
        let hasLower   = pw.range(of: "[a-z]",        options: .regularExpression) != nil
        let hasDigit   = pw.range(of: "[0-9]",        options: .regularExpression) != nil
        let hasSpecial = pw.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
        return hasUpper && hasLower && hasDigit && hasSpecial
    }
}

// MARK: - MnemonicRevealView

/// Shows the 24 BIP39 mnemonic words and requires the user to explicitly
/// acknowledge that losing the phrase means losing the account.
/// There is no server-side recovery — this is the only backup.
struct MnemonicRevealView: View {
    let mnemonic: [String]
    let onConfirmed: () -> Void

    @State private var hasAcknowledged = false
    @State private var showConfirmAlert = false

    private let columns = Array(repeating: GridItem(.flexible()), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Warning header
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)

                        Text("Save Your Recovery Phrase")
                            .font(.title2)
                            .bold()

                        Text("These 24 words are the **only** way to recover your account. KyberChat has no password reset and no support team that can restore your account. If you lose these words, you lose your account — permanently.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()

                    // Word grid
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(mnemonic.enumerated()), id: \.offset) { index, word in
                            WordCard(number: index + 1, word: word)
                        }
                    }
                    .padding(.horizontal)

                    // Acknowledgement
                    VStack(spacing: 16) {
                        Toggle(isOn: $hasAcknowledged) {
                            Text("I have written down my recovery phrase and understand that losing it means losing my account.")
                                .font(.subheadline)
                        }
                        .padding(.horizontal)

                        Button {
                            showConfirmAlert = true
                        } label: {
                            Text("I've Saved It — Continue")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasAcknowledged)
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Recovery Phrase")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Are you sure?", isPresented: $showConfirmAlert) {
            Button("Yes, I've saved it", role: .destructive) {
                onConfirmed()
            }
            Button("Go Back", role: .cancel) { }
        } message: {
            Text("You will NOT be able to view this phrase again. Make sure it is stored safely before continuing.")
        }
    }
}

// MARK: - WordCard

private struct WordCard: View {
    let number: Int
    let word: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(number)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(word)
                .font(.system(.body, design: .monospaced))
                .bold()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
