import SwiftUI

struct HomeView: View {
    @Binding var isLoggedIn: Bool

    var body: some View {
        VStack {
            Spacer()
            Text("Yay")
                .font(.largeTitle)
                .bold()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
