import AppKit

struct DirectoryPicker {
    static func selectDirectory(title: String = "Select Directory", completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.title = title
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true

            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}
