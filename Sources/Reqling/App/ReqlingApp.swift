import SwiftUI

@main
struct ReqlingApp: App {
    private let component = AppDI.component

    var body: some Scene {
        Window(component.appInfo.name, id: "main") {
            ContentView(appInfo: component.appInfo)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
