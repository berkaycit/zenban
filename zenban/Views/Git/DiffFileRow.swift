import SwiftUI

struct DiffFileRow: View {
    let file: FileChange
    @Binding var isExpanded: Bool
    let diffContent: String?
    var onNeedsDiff: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeaderRow

            if isExpanded {
                if let diff = diffContent, !diff.isEmpty {
                    DiffContentView(diffText: diff)
                        .padding(.top, 1)
                } else {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading diff...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .onAppear {
                        onNeedsDiff?()
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var fileHeaderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 12)

            statusIcon

            Text(file.path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            HStack(spacing: 8) {
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                }
                if file.deletions > 0 {
                    Text("-\(file.deletions)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch file.status {
        case .added, .untracked:
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.green)
        case .modified:
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.orange)
        case .deleted:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
        case .renamed:
            Image(systemName: "arrow.triangle.swap")
                .foregroundStyle(.blue)
        }
    }
}
