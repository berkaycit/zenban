import SwiftUI

struct SettingsView: View {
    var body: some View {
        TerminalSettingsView()
            .navigationTitle("Terminal")
            .frame(minWidth: 520, minHeight: 360)
    }
}
