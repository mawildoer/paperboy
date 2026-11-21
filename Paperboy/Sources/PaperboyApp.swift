import SwiftUI

@main
struct PaperboyApp: App {
    @StateObject private var coordinator = SyncCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Runs at every launch, including background launches by iOS (Bluetooth state
        // restoration, background tasks), before the app finishes launching.
        let coordinator = SyncCoordinator.shared
        #if os(iOS)
        coordinator.registerBackgroundTasks()
        #endif
        coordinator.bluetooth.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.bluetooth)
                .environmentObject(AppLog.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                coordinator.appOpened()
            case .background:
                #if os(iOS)
                coordinator.scheduleBackgroundTasks()
                #endif
            default:
                break
            }
        }
    }
}
