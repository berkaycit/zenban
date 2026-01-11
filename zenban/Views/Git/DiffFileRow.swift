import SwiftUI

struct DiffFileRow: View {
    let file: FileChange
    let isSelected: Bool
    let onSelect: () -> Void

    private var fileName: String {
        (file.path as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            statusIcon

            Text(fileName)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            HStack(spacing: 6) {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
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
