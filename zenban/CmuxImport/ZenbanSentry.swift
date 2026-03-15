import Foundation
import Sentry

enum ZenbanSentry {
    private static let startupLock = NSLock()
    private static var started = false

    static func startAppIfNeeded() {
        guard TelemetrySettings.enabledForCurrentLaunch else { return }

        startupLock.lock()
        defer { startupLock.unlock() }

        guard !started else { return }
        guard let config = ZenbanSentrySettings.load() else {
            NSLog("ZenbanSentry: missing SentryConfig.plist; telemetry disabled for this launch")
            return
        }
        installSentryCompressionFixIfNeeded()

        // Pre-warm locale before Sentry to avoid a startup data race.
        // Locale initialization (os.locale.ensureLocale / NSLocale._preferredLanguages)
        // on the main thread can race with Sentry's background init thread
        // calling posix.getenv, causing a SIGSEGV shortly after launch.
        _ = Locale.current
        _ = NSLocale.preferredLanguages

        SentrySDK.start { options in
            config.applyRuntimeOptions(
                options,
                cli: false,
                tracesSampleRate: 0.1,
                appHangTimeoutInterval: 8.0
            )
        }

        started = true
    }
}
