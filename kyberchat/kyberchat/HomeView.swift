import SwiftUI

/// Root of the authenticated app. Delegates entirely to FriendsListView.
/// This thin wrapper exists so ContentView doesn't need to know about the
/// internal view hierarchy — just replace FriendsListView with a TabView
/// here when additional top-level tabs are added.
struct HomeView: View {
    var body: some View {
        FriendsListView()
    }
}
