import Foundation
#if canImport(Sentry)
import Sentry
#endif

struct ZenbanSentrySettings: Decodable {
    let dsn: String
    let sendDefaultPii: Bool

    private static let resourceName = "SentryConfig"

    static func load(bundle: Bundle = .main, executableURL: URL? = nil) -> ZenbanSentrySettings? {
        guard let bundle = runtimeBundle(bundle: bundle, executableURL: executableURL),
              let url = bundle.url(forResource: resourceName, withExtension: "plist"),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        return try? PropertyListDecoder().decode(ZenbanSentrySettings.self, from: data)
    }

    static func releaseName(
        bundle: Bundle = .main,
        executableURL: URL? = nil,
        bundleIdentifierOverride: String? = nil
    ) -> String? {
        guard let resolvedBundle = runtimeBundle(bundle: bundle, executableURL: executableURL) else {
            return nil
        }

        let bundleIdentifier = normalizedBundleIdentifier(
            bundle: resolvedBundle,
            bundleIdentifierOverride: bundleIdentifierOverride
        )
        guard let bundleIdentifier,
              let version = bundleVersionValue(forKey: "CFBundleShortVersionString", bundle: resolvedBundle),
              let build = bundleVersionValue(forKey: "CFBundleVersion", bundle: resolvedBundle)
        else {
            return nil
        }

        return "\(bundleIdentifier)@\(version)+\(build)"
    }

    static func environmentName(isDebug: Bool, cli: Bool) -> String {
        switch (isDebug, cli) {
        case (true, true):
            return "development-cli"
        case (false, true):
            return "production-cli"
        case (true, false):
            return "development"
        case (false, false):
            return "production"
        }
    }

    private static func runtimeBundle(bundle: Bundle, executableURL: URL?) -> Bundle? {
        if bundleContainsResource(bundle) {
            return bundle
        }

        if bundleContainsResource(.main) {
            return .main
        }

        guard let executableURL = executableURL ?? currentExecutableURL() else {
            return nil
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app", let appBundle = Bundle(url: current), bundleContainsResource(appBundle) {
                return appBundle
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app", let appBundle = Bundle(url: appURL), bundleContainsResource(appBundle) {
                    return appBundle
                }
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || parent.path == "/" {
                break
            }
            current = parent
        }

        return nil
    }

    private static func bundleContainsResource(_ bundle: Bundle) -> Bool {
        bundle.url(forResource: resourceName, withExtension: "plist") != nil
    }

    private static func normalizedBundleIdentifier(bundle: Bundle, bundleIdentifierOverride: String?) -> String? {
        if let bundleIdentifierOverride {
            let trimmed = bundleIdentifierOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        guard let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bundleVersionValue(forKey key: String, bundle: Bundle) -> String? {
        guard let value = bundle.infoDictionary?[key] as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    private static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
            }
        }

        return Bundle.main.executableURL?.standardizedFileURL
    }
}

#if canImport(Sentry)
extension ZenbanSentrySettings {
    private static let isDebugBuild: Bool = {
#if DEBUG
        true
#else
        false
#endif
    }()

    func applyRuntimeOptions(
        _ options: Options,
        executableURL: URL? = nil,
        bundleIdentifierOverride: String? = nil,
        cli: Bool,
        tracesSampleRate: Double,
        appHangTimeoutInterval: TimeInterval? = nil
    ) {
        options.dsn = dsn
        options.releaseName = Self.releaseName(
            executableURL: executableURL,
            bundleIdentifierOverride: bundleIdentifierOverride
        )
        options.environment = Self.environmentName(isDebug: Self.isDebugBuild, cli: cli)
        options.debug = Self.isDebugBuild
        options.sendDefaultPii = sendDefaultPii
        options.attachStacktrace = true
        options.tracesSampleRate = NSNumber(value: tracesSampleRate)
        options.enableCaptureFailedRequests = false
        if let appHangTimeoutInterval {
            options.appHangTimeoutInterval = appHangTimeoutInterval
        }
    }
}
#endif
