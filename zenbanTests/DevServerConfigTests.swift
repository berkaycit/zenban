import Foundation
import Testing
@testable import zenban

struct DevServerConfigTests {
    @Test
    func missingAutoOpenConsoleDecodesAsFalse() throws {
        let data = """
        {
          "setupCommand": "npm install",
          "devCommand": "npm run dev",
          "skipSetup": true
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(DevServerConfig.self, from: data)

        #expect(config.setupCommand == "npm install")
        #expect(config.devCommand == "npm run dev")
        #expect(config.skipSetup)
        #expect(config.autoOpenConsole == false)
    }
}
