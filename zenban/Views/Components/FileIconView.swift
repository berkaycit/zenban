import SwiftUI

struct FileIconView: View {
    let path: String
    let size: CGFloat

    @State private var icon: NSImage?

    init(path: String, size: CGFloat = 16) {
        self.path = path
        self.size = size
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "doc")
                    .resizable()
                    .frame(width: size, height: size)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: path) {
            icon = FileIconService.shared.icon(
                forFile: path,
                size: CGSize(width: size, height: size)
            )
        }
    }
}
