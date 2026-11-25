import SwiftUI

/// Trailing inspector content hosting Prep and To-Dos as tabs. The segmented
/// control only appears when prep exists; otherwise the inspector is just the
/// to-dos panel.
struct NotesEditorInspector: View {
    @Bindable var meeting: Meeting
    let prepPresentation: MeetingPrepPresentation
    @Binding var inspectorTab: InspectorTab

    @AppStorage(AppPreferenceKey.useNativeMarkdownEditor) private var useNativeMarkdownEditor = false

    private var effectiveInspectorTab: InspectorTab {
        prepPresentation.hasPrep ? inspectorTab : .todos
    }

    var body: some View {
        VStack(spacing: 0) {
            if prepPresentation.hasPrep {
                Picker("Inspector tab", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(CasaSpace.md)

                Divider()
            }

            if effectiveInspectorTab == .prep {
                Group {
                    if useNativeMarkdownEditor {
                        NativeMarkdownViewer(markdown: prepPresentation.markdownText)
                    } else {
                        ToastMarkdownViewer(markdown: prepPresentation.markdownText)
                    }
                }
                .padding(CasaSpace.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                MeetingTodosPanel(meeting: meeting)
            }
        }
    }
}
