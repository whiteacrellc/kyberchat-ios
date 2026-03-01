//
//  ContentView.swift
//  kyberchat
//
//  Created by tom whittaker on 3/1/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isLoggedIn = false

    var body: some View {
        if isLoggedIn {
            HomeView(isLoggedIn: $isLoggedIn)
        } else {
            NavigationStack {
                LoginView(isLoggedIn: $isLoggedIn)
            }
        }
    }
}

#Preview {
    ContentView()
}
