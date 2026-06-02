#if os(macOS)
import SwiftUI
import AppKit

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                defaultAppSection
                Divider()
                quickLookSection
                Divider()
                shortcutsSection
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 680,
               minHeight: 520, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Marklens Help")
                .font(.system(size: 28, weight: .semibold))
            Text("A fast, native Markdown viewer for macOS and iPadOS.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Set as default app

    private var defaultAppSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open all .md files in Marklens by default")
                .font(.title2.bold())
            Text("Once set as the default, double-clicking any Markdown file in Finder will open it in Marklens.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HelpStep(number: 1,
                         title: "Find a .md file in Finder.",
                         detail: "Any Markdown file works — the project's README, a note, anything ending in .md or .markdown.")
                HelpStep(number: 2,
                         title: "Right-click the file → Get Info.",
                         detail: "Or select the file and press ⌘I.")
                HelpStep(number: 3,
                         title: "Expand the \"Open with:\" section.",
                         detail: "Click the disclosure triangle if it's collapsed, then pick Marklens from the dropdown.")
                HelpStep(number: 4,
                         title: "Click \"Change All…\" and confirm.",
                         detail: "macOS will route every .md file to Marklens from now on.")
            }
            .padding(.top, 4)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("If Marklens isn't in the dropdown, choose Other… and pick Marklens from the Applications folder.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
    }

    // MARK: - Quick Look

    private var quickLookSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview without opening — Quick Look")
                .font(.title2.bold())
            Text("Select any .md file in Finder and press Space. Marklens's Quick Look extension renders the file inline using the same engine as the app, so code highlighting and Mermaid diagrams show up immediately.")
                .foregroundStyle(.secondary)
            Text("If Quick Look shows the raw text instead of a rendered preview, open Terminal and run:")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("pluginkit -e use -i solutions.ddj.marklens.QuickLook")
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts")
                .font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                shortcutRow("Open file…", "⌘O")
                shortcutRow("Zoom in", "⌘=")
                shortcutRow("Zoom out", "⌘−")
                shortcutRow("Actual size", "⌘0")
                shortcutRow("Export as PDF", "⌘⇧E")
                shortcutRow("Close window", "⌘W")
            }
        }
    }

    private func shortcutRow(_ name: String, _ keys: String) -> some View {
        GridRow {
            Text(name)
            Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

private struct HelpStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    HelpView()
}
#endif
