import SwiftUI
import AppKit

struct UpdatePromptView: View {
    let release: ReleaseInfo
    let onInstall: () -> Void
    let onLater: () -> Void
    let onSkip: () -> Void

    private var renderedReleaseNotes: AttributedString {
        let rendered = MarkdownConverter.markdownToAttributedString(
            release.bodyMarkdown,
            baseFont: .systemFont(ofSize: NSFont.systemFontSize)
        )
        return AttributedString(rendered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Casablanca \(release.version.description) is available")
                .font(.title2.bold())
            Text("You're running \(Bundle.main.shortVersionString). Updating restarts the app.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(renderedReleaseNotes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .padding(.horizontal, 4)

            HStack {
                Button("Skip This Version", action: onSkip)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Remind Me Later", action: onLater)
                    .buttonStyle(.bordered)
                Button("Install Update", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private extension Bundle {
    var shortVersionString: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }
}
