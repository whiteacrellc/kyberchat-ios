# KyberChat iOS — Claude Code Guide

## Project Overview
A zero-knowledge, end-to-end encrypted chat application. This repo is the **iOS client**.

- **Privacy model:** No phone numbers, no emails. Identity via BIP39 Mnemonic Seed Phrases.
- **Encryption protocol:** Signal Protocol (X3DH key agreement + Double Ratchet messaging).
- **Backend:** GCP (Cloud Run/GKE, Cloud SQL/MySQL for key directory, Firestore for message relay).

---

## Technical Stack

### This Repo (iOS Client)
- **Language:** Swift
- **UI:** SwiftUI
- **Persistence:** SwiftData (local store)
- **Crypto:** `LibSignalProtocolSwift` (Signal Protocol implementation)
- **Identity:** Client-side UUID generation + BIP39 mnemonic for account recovery

### Android Client (separate repo)
- Kotlin + `libsignal-protocol-android`

### Backend (GCP)
- **Compute:** Cloud Run (serverless) or GKE
- **Key Directory:** Cloud SQL (MySQL) — stores public key bundles
- **Message Relay:** Cloud Firestore — stores encrypted blobs, real-time listeners for delivery

---

## Architecture

### Identity & Onboarding
Users have no PII account. On first launch:
1. Generate a UUID locally.
2. Generate a BIP39 mnemonic — this IS the identity recovery mechanism.
3. Derive Signal Protocol key material from the mnemonic seed.
4. Register the public key bundle (Identity Key, Signed Pre-Key, One-Time Pre-Keys) with the backend key directory.

### Sending a Message (X3DH + Double Ratchet)
1. Fetch recipient's key bundle from Cloud SQL via the backend API.
2. Perform X3DH to establish a shared secret.
3. Initialize a Double Ratchet session.
4. Encrypt the message payload; upload the ciphertext blob to Firestore.
5. Recipient's device listens via Firestore real-time listener, downloads and decrypts.

### Zero-Knowledge Principle
- The server never sees plaintext. It only stores encrypted blobs and public keys.
- User lookup is by username or UUID — no phone/email stored anywhere.

---

## MySQL Schema (Key Directory — Backend)

```sql
CREATE TABLE users (
    user_uuid CHAR(36) PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    identity_key_public BLOB NOT NULL,
    registration_id INT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE signed_pre_keys (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_uuid CHAR(36) NOT NULL,
    key_id INT NOT NULL,
    public_key BLOB NOT NULL,
    signature BLOB NOT NULL,
    FOREIGN KEY (user_uuid) REFERENCES users(user_uuid) ON DELETE CASCADE
);

CREATE TABLE one_time_pre_keys (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_uuid CHAR(36) NOT NULL,
    key_id INT NOT NULL,
    public_key BLOB NOT NULL,
    is_consumed BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (user_uuid) REFERENCES users(user_uuid) ON DELETE CASCADE
);
```

---

## Project Structure

```
kyberchat/
├── kyberchat.xcodeproj/
└── kyberchat/
    ├── kyberchatApp.swift      # App entry point, SwiftData ModelContainer setup
    ├── ContentView.swift       # Root view (placeholder — replace with real UI)
    ├── Item.swift              # SwiftData model (placeholder)
    └── Assets.xcassets/
```

---

## Development Conventions

- **SwiftUI only** — no UIKit unless strictly required by a third-party library.
- **SwiftData** for local persistence (sessions, cached messages, key material).
- All crypto operations must happen off the main thread (use `async/await` with actors or background tasks).
- Never log plaintext message content or key material — not even in DEBUG builds.
- Prefer `async/await` over completion handlers for all async work.
- Keep crypto and networking logic out of View files — use ViewModels or service objects.

## Build & Run

Open `kyberchat/kyberchat.xcodeproj` in Xcode. No package manager CLI setup required; Swift Package Manager handles dependencies via Xcode.

```bash
# Build from CLI (optional)
xcodebuild -project kyberchat/kyberchat.xcodeproj \
           -scheme kyberchat \
           -destination 'platform=iOS Simulator,name=iPhone 16' \
           build

# Run tests
xcodebuild test \
           -project kyberchat/kyberchat.xcodeproj \
           -scheme kyberchat \
           -destination 'platform=iOS Simulator,name=iPhone 16'
```
