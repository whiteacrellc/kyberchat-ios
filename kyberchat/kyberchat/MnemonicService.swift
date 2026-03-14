import Foundation
import CryptoKit
import CommonCrypto
// swift-crypto 3.3+ — add via Swift Package Manager:
//   https://github.com/apple/swift-crypto  (tag: 3.3.0 or later)
//   Product: .product(name: "Crypto", package: "swift-crypto")
// This import will fail to compile until the SPM dependency is added.
import Crypto

// MARK: - MnemonicService
//
// Implements BIP39 mnemonic generation and deterministic key derivation.
//
// Derivation chain:
//   CSPRNG (32 bytes entropy)
//     └─► BIP39 mnemonic (24 words)
//           └─► PBKDF2-HMAC-SHA512(mnemonic, salt="mnemonic", 2048 iters) → 64-byte master seed
//                 ├─► HKDF(seed, info="kyberchat-uuid")          → user_uuid (deterministic)
//                 ├─► HKDF(seed, info="kyberchat-identity-key")  → X25519 private key (32 bytes)
//                 ├─► HKDF(seed, info="kyberchat-signing-key")   → Ed25519 private key (32 bytes)
//                 ├─► HKDF(seed, info="kyberchat-registration")  → registration_id (2 bytes → UInt16)
//                 └─► HKDF(seed, info="kyberchat-kem-seed")      → 64-byte ML-KEM-768 seed
//
// ML-KEM-768 (CRYSTALS-Kyber) — DEPENDENCY REQUIRED:
//   Add swift-crypto 3.3+ via Swift Package Manager:
//     https://github.com/apple/swift-crypto  (tag: 3.3.0 or later)
//   Then add to Package.swift: .product(name: "Crypto", package: "swift-crypto")
//   API: let kemPriv = try MLKem768.PrivateKey(seed: kemSeedData)  // 64 bytes
//        let kemPubHex = Data(kemPriv.publicKey.rawRepresentation).hexString  // 1184 bytes
//
// The master seed is stored in Keychain. All keys are re-derivable from it.
// SPK/OTPK private keys are stored separately since they rotate.

enum MnemonicError: Error, LocalizedError {
    case entropyGenerationFailed
    case invalidMnemonic
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .entropyGenerationFailed: return "Failed to generate secure random entropy."
        case .invalidMnemonic:         return "Invalid mnemonic phrase."
        case .keyDerivationFailed:     return "Key derivation failed."
        }
    }
}

/// The full set of identity material derived from a BIP39 mnemonic seed.
struct DerivedIdentity {
    let userUUID:          String   // deterministic UUID string
    let registrationID:    Int      // 1–65535
    let identityKeyPriv:   Curve25519.KeyAgreement.PrivateKey
    let signingKeyPriv:    Curve25519.Signing.PrivateKey
    /// 64-byte seed for ML-KEM-768 key generation (pass to MLKem768.PrivateKey(seed:))
    let kemSeed:           Data

    /// Hex-encoded X25519 public key — sent to the server on registration
    var identityKeyPublicHex: String {
        identityKeyPriv.publicKey.rawRepresentation.hexString
    }
}

enum MnemonicService {

    // MARK: - Generate new mnemonic

    /// Generates a new 24-word BIP39 mnemonic from 256 bits of secure random entropy.
    static func generateMnemonic() throws -> [String] {
        var entropy = Data(count: 32)
        let status = entropy.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw MnemonicError.entropyGenerationFailed }
        return try entropyToMnemonic(entropy)
    }

    // MARK: - Entropy ↔ Mnemonic

    static func entropyToMnemonic(_ entropy: Data) throws -> [String] {
        guard entropy.count == 32 else { throw MnemonicError.invalidMnemonic }

        // Compute SHA-256 checksum byte
        let hash = SHA256.hash(data: entropy)
        let checksumByte = hash.first!

        // Combine 256-bit entropy + 8-bit checksum = 264 bits
        var bits = entropy + Data([checksumByte])

        // Split into 24 × 11-bit indices
        var indices: [Int] = []
        var bitBuffer: UInt32 = 0
        var bitsInBuffer = 0

        for byte in bits {
            bitBuffer = (bitBuffer << 8) | UInt32(byte)
            bitsInBuffer += 8
            if bitsInBuffer >= 11 {
                bitsInBuffer -= 11
                indices.append(Int((bitBuffer >> bitsInBuffer) & 0x7FF))
            }
        }

        guard indices.count == 24 else { throw MnemonicError.invalidMnemonic }
        return indices.map { BIP39Wordlist.words[$0] }
    }

    // MARK: - Seed derivation

    /// Derives the 64-byte BIP39 master seed from a mnemonic word array.
    /// Uses PBKDF2-HMAC-SHA512 with 2048 iterations and salt = "mnemonic".
    static func mnemonicToSeed(_ words: [String], passphrase: String = "") throws -> Data {
        let mnemonic = words.joined(separator: " ")
        guard let passwordData = mnemonic.data(using: .utf8),
              let saltData = ("mnemonic" + passphrase).data(using: .utf8) else {
            throw MnemonicError.keyDerivationFailed
        }

        var derivedKey = Data(count: 64)
        let status = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            passwordData.withUnsafeBytes { passwordPtr in
                saltData.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress, passwordData.count,
                        saltPtr.baseAddress,     saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        2048,
                        derivedKeyPtr.baseAddress, 64
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw MnemonicError.keyDerivationFailed }
        return derivedKey
    }

    // MARK: - Key derivation from seed

    /// Derives all identity material from a 64-byte master seed.
    static func deriveIdentity(from seed: Data) throws -> DerivedIdentity {
        guard seed.count == 64 else { throw MnemonicError.keyDerivationFailed }

        let inputKey = SymmetricKey(data: seed)

        // X25519 identity key (32 bytes)
        let ikBytes = hkdf(inputKey: inputKey, info: "kyberchat-identity-key", outputByteCount: 32)
        let identityKeyPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ikBytes)

        // Ed25519 signing key (32 bytes)
        let skBytes = hkdf(inputKey: inputKey, info: "kyberchat-signing-key", outputByteCount: 32)
        let signingKeyPriv = try Curve25519.Signing.PrivateKey(rawRepresentation: skBytes)

        // Deterministic UUID (16 bytes → UUID)
        let uuidBytes = hkdf(inputKey: inputKey, info: "kyberchat-uuid", outputByteCount: 16)
        let userUUID = uuidBytes.withUnsafeBytes { ptr in
            UUID(uuid: ptr.load(as: uuid_t.self))
        }.uuidString

        // Registration ID (2 bytes → 1–65535)
        let regBytes = hkdf(inputKey: inputKey, info: "kyberchat-registration", outputByteCount: 2)
        let regRaw = regBytes.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let registrationID = Int(regRaw == 0 ? 1 : regRaw)  // ensure non-zero

        // ML-KEM-768 seed (64 bytes) — use with MLKem768.PrivateKey(seed:) from swift-crypto 3.3+
        let kemSeed = hkdf(inputKey: inputKey, info: "kyberchat-kem-seed", outputByteCount: 64)

        return DerivedIdentity(
            userUUID: userUUID,
            registrationID: registrationID,
            identityKeyPriv: identityKeyPriv,
            signingKeyPriv: signingKeyPriv,
            kemSeed: kemSeed
        )
    }

    // MARK: - Keychain persistence

    /// Saves the master seed to Keychain and derives + returns identity.
    static func persistSeedAndDeriveIdentity(seed: Data) throws -> DerivedIdentity {
        let identity = try deriveIdentity(from: seed)

        // Store master seed (all keys can be re-derived from this)
        KeychainHelper.save(seed, account: KeychainAccount.masterSeed.rawValue)

        // Cache the identity private key separately for fast access during E2EE ops
        KeychainHelper.save(
            identity.identityKeyPriv.rawRepresentation,
            account: KeychainAccount.identityPrivateKey.rawValue
        )
        KeychainHelper.save(
            identity.signingKeyPriv.rawRepresentation,
            account: KeychainAccount.signingPrivateKey.rawValue
        )

        return identity
    }

    /// Restores the identity from the Keychain-stored master seed.
    /// Returns `nil` if no seed is stored (new device / first install).
    static func restoreIdentity() -> DerivedIdentity? {
        guard let seed = KeychainHelper.readData(account: KeychainAccount.masterSeed.rawValue) else {
            return nil
        }
        return try? deriveIdentity(from: seed)
    }

    // MARK: - ML-KEM-768 helpers

    /// Derives the ML-KEM-768 public key (1184 bytes, hex-encoded) from a 64-byte seed.
    ///
    /// Requires swift-crypto 3.3+. The `Crypto` module must be added via SPM:
    ///   https://github.com/apple/swift-crypto  (tag: 3.3.0 or later)
    ///
    /// The seed itself (not the private key bytes) is what gets stored in the Keychain
    /// and registered with the server — it can be re-derived from the master seed at any time.
    static func kemPublicKeyHex(from kemSeed: Data) throws -> String {
        guard kemSeed.count == 64 else { throw MnemonicError.keyDerivationFailed }
        let kemPriv = try MLKem768.PrivateKey(seed: kemSeed)
        return Data(kemPriv.publicKey.rawRepresentation).hexString
    }

    // MARK: - Private helpers

    private static func hkdf(inputKey: SymmetricKey, info: String, outputByteCount: Int) -> Data {
        let infoData = Data(info.utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            info: infoData,
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Data hex helper

extension Data {
    /// Hex-encoded string representation
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
