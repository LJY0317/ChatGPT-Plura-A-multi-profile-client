import SwiftUI

struct RootView: View {
    var body: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-mcp-form") {
            RemoteMcpElicitationTestHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--ui-testing-plura-shell") {
            RemoteHomeView()
        } else if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            NavigationStack {
                ChatScreen()
            }
        } else {
            RemoteHomeView()
        }
#else
        RemoteHomeView()
#endif
    }
}
