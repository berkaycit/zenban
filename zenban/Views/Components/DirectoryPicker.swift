import AppKit

struct DirectoryPicker {
    static func selectDirectory(title: String = "Select Directory") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK {
            return panel.url
        }
        return nil
    }
}
