import SwiftUI

/// Shown when the open document embeds images we aren't allowed to read.
///
/// Markdown can't embed an image — `![](…)` is always a pointer at another file
/// — and a sandboxed app is handed the document and nothing else. So the images
/// in someone else's README are, by default, unreadable, and they'd render as
/// silent blank gaps. This says so, and offers the one thing that fixes it.
struct ImageAccessBanner: View {
    let folderName: String
    let allow: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Images in this document aren't shown")
                    .font(.callout.weight(.medium))
                Text("Allow Marklens to read “\(folderName)” to display them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Allow…", action: allow)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}