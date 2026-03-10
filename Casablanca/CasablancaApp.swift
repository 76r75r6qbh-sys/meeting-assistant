import SwiftUI
import SwiftData

@main
struct CasablancaApp: App {
    @State private var calendarService = CalendarService()
    @State private var permissionsManager = PermissionsManager()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: MeetingListViewModel(calendarService: calendarService))
                .frame(
                    minWidth: 800,
                    minHeight: 500
                )
                .task {
                    await permissionsManager.checkAll()
                    if calendarService.authorizationStatus == .fullAccess {
                        await calendarService.fetchUpcomingEvents()
                    }
                }
        }
        .modelContainer(for: Meeting.self)
        .defaultSize(
            width: CasaLayout.windowDefaultWidth,
            height: CasaLayout.windowDefaultHeight
        )
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
        }
    }
}
