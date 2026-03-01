import SwiftUI

/// A password text field with a right-side eye button to toggle between
/// hidden (SecureField) and plaintext (TextField) entry.
/// Matches the visual style of `textFieldStyle(.roundedBorder)`.
struct PasswordFieldView: View {
    let placeholder: String
    @Binding var text: String

    @State private var isVisible = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if isVisible {
                    TextField(placeholder, text: $text)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                } else {
                    SecureField(placeholder, text: $text)
                        .focused($isFocused)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                let wasFocused = isFocused
                isVisible.toggle()
                if wasFocused {
                    // Brief delay lets the view swap before re-acquiring focus
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isFocused = true
                    }
                }
            } label: {
                Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(UIColor.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(UIColor.systemGray4), lineWidth: 0.5)
        )
    }
}

#Preview {
    @Previewable @State var text = ""
    PasswordFieldView(placeholder: "Password", text: $text)
        .padding()
}
