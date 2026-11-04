import SwiftUI

@main
struct ReqlingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let component = AppDI.component

    var body: some Scene {
        Window(component.appInfo.name, id: "main") {
            ContentView(model: component.appModel)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            ReqlingCommands(model: component.appModel)
        }
    }
}
