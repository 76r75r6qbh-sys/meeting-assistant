import SwiftUI
import SwiftData

@main
struct CasablancaApp: App {
    static let mainWindowID = "main-window"

    @State private var appModel = AppModel()
    private let sharedModelContainer: ModelContainer

    init() {
        do {
            sharedModelContainer = try ModelContainer(for: Meeting.self, TodoItem.self)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(viewModel: appModel.meetingListViewModel)
                .frame(
                    minWidth: 800,
                    minHeight: 500
                )
                .task {
                    await appModel.permissionsManager.checkAll()
                    if appModel.calendarService.authorizationStatus == .fullAccess {
                        await appModel.calendarService.fetchUpcomingEvents()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(
            width: CasaLayout.windowDefaultWidth,
            height: CasaLayout.windowDefaultHeight
        )
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Manual Meeting") {
                    appModel.meetingListViewModel.beginManualMeeting()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        MenuBarExtra("Casablanca", systemImage: "record.circle") {
            MenuBarMeetingView(viewModel: appModel.meetingListViewModel)
        }
        .modelContainer(sharedModelContainer)
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

@Observable
private final class AppModel {
    let calendarService = CalendarService()
    let permissionsManager = PermissionsManager()
    let meetingListViewModel: MeetingListViewModel

    init() {
        meetingListViewModel = MeetingListViewModel(calendarService: calendarService)
    }
}
