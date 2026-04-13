import SwiftUI

struct RecordingView: View {
    @Bindable var meeting: Meeting
    @Bindable var recordingService: AudioRecordingService
    let onBack: () -> Void

    var body: some View {
        NotesEditorView(
            meeting: meeting,
            recordingService: recordingService,
            autoStartRecording: true,
            onBack: onBack
        )
    }
}
