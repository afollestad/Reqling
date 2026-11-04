import ReqlingKit
import SwiftUI

/// The main window's root view.
struct ContentView: View {
    let appInfo: AppInfo

    var body: some View {
        ContentUnavailableView {
            Label(appInfo.name, systemImage: "curlybraces")
        } description: {
            Text("Version \(appInfo.version) (\(appInfo.build))")
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
