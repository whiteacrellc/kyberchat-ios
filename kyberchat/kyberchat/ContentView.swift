//
//  ContentView.swift
//  kyberchat
//
//  Created by tom whittaker on 3/1/26.
//

import SwiftUI

/// Root view. Observes `SessionManager` to drive navigation between
/// the login stack and the main app. Auto-login is attempted on appear.
struct ContentView: View {
    @State private var session = SessionManager.shared

    var body: some View {
        Group {
            if session.isLoggedIn {
                HomeView()
            } else {
                NavigationStack {
                    LoginView()
                }
            }
        }
        .environment(session)
        .onAppear {
            session.restoreSession()
        }
    }
}

#Preview {
    ContentView()
}
