import SwiftUI

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Zenban")
                            .font(.title2)
                            .fontWeight(.semibold)

                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("Version \(version)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
    }
}
