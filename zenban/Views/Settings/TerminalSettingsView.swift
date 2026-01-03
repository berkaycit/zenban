import SwiftUI
import AppKit

struct TerminalSettingsView: View {
    @AppStorage("terminalFontName") private var fontName = "Menlo"
    @AppStorage("terminalFontSize") private var fontSize = 14.0
    @AppStorage("terminalThemeName") private var themeName = "Dracula"
    @AppStorage("terminalThemeNameLight") private var themeNameLight = "Builtin Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = false
    @AppStorage("cleanupSessionsOnQuit") private var cleanupSessionsOnQuit = false

    @State private var availableFonts: [String] = []
    @State private var themeNames: [String] = []
    @State private var clearingSessions = false

    private static var themesPath: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        return (resourcePath as NSString).appendingPathComponent("ghostty/themes")
    }

    private func loadSystemFonts() -> [String] {
        let fontManager = NSFontManager.shared
        let monospaceFonts = fontManager.availableFontFamilies.filter { familyName in
            guard let font = NSFont(name: familyName, size: 12) else { return false }
            return font.isFixedPitch
        }

        var fonts = monospaceFonts.sorted()
        if !fonts.contains(fontName) {
            fonts.insert(fontName, at: 0)
        }
        return fonts
    }

    private func loadThemeNames() -> [String] {
        guard let themesPath = Self.themesPath else {
            return []
        }

        guard let themeFiles = try? FileManager.default.contentsOfDirectory(atPath: themesPath) else {
            return []
        }

        return themeFiles.filter { file in
            let path = (themesPath as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return !isDir.boolValue && !file.hasPrefix(".")
        }.sorted()
    }

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font", selection: $fontName) {
                    ForEach(availableFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }
                .disabled(availableFonts.isEmpty)

                HStack {
                    Text("Size \(Int(fontSize))")
                        .frame(width: 90, alignment: .leading)

                    Slider(value: $fontSize, in: 8...24, step: 1)

                    Stepper("", value: $fontSize, in: 8...24, step: 1)
                        .labelsHidden()
                }
            }

            Section("Theme") {
                Toggle("Use different themes for Light/Dark mode", isOn: $usePerAppearanceTheme)

                if usePerAppearanceTheme {
                    Picker("Dark Mode Theme", selection: $themeName) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)

                    Picker("Light Mode Theme", selection: $themeNameLight) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)
                } else {
                    Picker("Theme", selection: $themeName) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)
                }
            }

            Section("Sessions") {
                Toggle("Clean up sessions on quit", isOn: $cleanupSessionsOnQuit)

                Button {
                    clearingSessions = true
                    Task {
                        await TmuxSessionManager.shared.killAllZenbanSessions()
                        clearingSessions = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if clearingSessions {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Kill All Sessions")
                    }
                }
                .disabled(clearingSessions)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if availableFonts.isEmpty {
                availableFonts = loadSystemFonts()
            }
            if themeNames.isEmpty {
                themeNames = loadThemeNames()
            }
        }
    }
}
