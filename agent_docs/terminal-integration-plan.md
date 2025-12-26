# Terminal Integration Plan: SwiftTerm + tmux

Bu dokuman, Zenban uygulamasina kalici terminal session'lari eklemek icin detayli implementasyon planini icerir.

## Ozet

Her kart icin kalici terminal session'i saglamak amaciyla **SwiftTerm** kutuphanesi ve **tmux** backend kombinasyonu kullanilacak. Bu yaklasim:
- Bellek verimli (tek terminal view, coklu tmux session)
- Gercek persistence (uygulama kapansa bile session'lar korunur)
- Production-tested (Secure Shellfish, La Terminal uygulamalarinda kullaniliyor)

---

## Mimari Genel Bakis

```
+-------------------+      +------------------+      +------------------+
|   CardDetailView  | ---> | TerminalManager  | ---> |   tmux server    |
|   (SwiftUI)       |      | (@Observable)    |      |   (background)   |
+-------------------+      +------------------+      +------------------+
         |                         |                         |
         v                         v                         v
+-------------------+      +------------------+      +------------------+
| TerminalContainer |      | SwiftTerm        |      | tmux sessions    |
| (NSViewRepresent.)|      | LocalProcess     |      | (per card UUID)  |
+-------------------+      +------------------+      +------------------+
```

---

## Teknoloji Kararlari

### SwiftTerm
- **Kutuphane**: https://github.com/migueldeicaza/SwiftTerm
- **Versiyon**: SPM ile `from: "1.0.0"`
- **Kullanilacak Siniflar**:
  - `LocalProcessTerminalView` - macOS AppKit NSView (terminal emulator)
  - `TerminalViewDelegate` - terminal event handling
  - `LocalProcess` - pty/process yonetimi

### tmux
- **Kullanim**: Session persistence backend
- **Gereksinim**: Kullanicida tmux yuklu olmali (veya bundle)
- **Session Adlandirma**: `zenban_card_<UUID>`

---

## Dosya Yapisi

```
zenban/
├── Terminal/
│   ├── TerminalManager.swift         # Session lifecycle yonetimi
│   ├── TerminalContainerView.swift   # NSViewRepresentable wrapper
│   ├── TmuxSessionController.swift   # tmux komut interface
│   └── TerminalConfiguration.swift   # Font, renk, boyut ayarlari
├── Views/
│   └── Card/
│       └── CardDetailView.swift      # Terminal view entegrasyonu
└── Extensions/
    └── Process+Async.swift           # Process async helper'lari
```

---

## Adim 1: SwiftTerm Paketini Ekle

### 1.1 Xcode'da Package Ekleme
```
File > Add Package Dependencies...
URL: https://github.com/migueldeicaza/SwiftTerm
Version: Up to Next Major (1.0.0)
```

### 1.2 Import Statement
```swift
import SwiftTerm
```

---

## Adim 2: TerminalConfiguration

Terminal gorunumu ve davranisi icin konfigürasyon struct'i.

```swift
// Terminal/TerminalConfiguration.swift

struct TerminalConfiguration {
    let fontName: String = "SF Mono"
    let fontSize: CGFloat = 12
    let backgroundColor: NSColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    let foregroundColor: NSColor = .white
    let cursorColor: NSColor = .green
    let scrollbackLines: Int = 10000

    var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}
```

---

## Adim 3: TmuxSessionController

tmux session yonetimi icin controller sinifi.

```swift
// Terminal/TmuxSessionController.swift

import Foundation

actor TmuxSessionController {

    enum TmuxError: Error {
        case tmuxNotInstalled
        case sessionCreationFailed(String)
        case sessionNotFound(String)
        case commandFailed(String)
    }

    private let tmuxPath: String

    init() async throws {
        // tmux yolunu bul
        let paths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw TmuxError.tmuxNotInstalled
        }
        self.tmuxPath = path
    }

    // MARK: - Session Management

    /// Kart icin session olustur veya mevcut session'i dondur
    func ensureSession(forCardID cardID: UUID) async throws -> String {
        let sessionName = sessionName(for: cardID)

        if try await sessionExists(sessionName) {
            return sessionName
        }

        try await createSession(sessionName)
        return sessionName
    }

    /// Session var mi kontrol et
    func sessionExists(_ name: String) async throws -> Bool {
        let result = try await runTmux(["has-session", "-t", name])
        return result.exitCode == 0
    }

    /// Yeni session olustur (detached)
    func createSession(_ name: String, workingDirectory: String? = nil) async throws {
        var args = ["new-session", "-d", "-s", name]

        if let dir = workingDirectory {
            args.append(contentsOf: ["-c", dir])
        }

        // Terminal boyutunu belirle
        args.append(contentsOf: ["-x", "120", "-y", "30"])

        let result = try await runTmux(args)
        if result.exitCode != 0 {
            throw TmuxError.sessionCreationFailed(result.stderr)
        }
    }

    /// Session'i sil
    func killSession(_ name: String) async throws {
        let _ = try await runTmux(["kill-session", "-t", name])
    }

    /// Tum Zenban session'larini listele
    func listZenbanSessions() async throws -> [String] {
        let result = try await runTmux(["list-sessions", "-F", "#{session_name}"])
        guard result.exitCode == 0 else { return [] }

        return result.stdout
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("zenban_card_") }
    }

    /// Kullanilmayan session'lari temizle
    func cleanupOrphanedSessions(activeCardIDs: Set<UUID>) async throws {
        let sessions = try await listZenbanSessions()

        for session in sessions {
            let uuidString = session.replacingOccurrences(of: "zenban_card_", with: "")
            if let uuid = UUID(uuidString: uuidString), !activeCardIDs.contains(uuid) {
                try? await killSession(session)
            }
        }
    }

    // MARK: - Helpers

    private func sessionName(for cardID: UUID) -> String {
        "zenban_card_\(cardID.uuidString)"
    }

    private func runTmux(_ args: [String]) async throws -> ProcessResult {
        try await Process.run(tmuxPath, arguments: args)
    }
}

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

extension Process {
    static func run(_ path: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { process in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

---

## Adim 4: TerminalManager

Session lifecycle ve SwiftTerm instance yonetimi.

```swift
// Terminal/TerminalManager.swift

import Foundation
import SwiftTerm
import AppKit

@Observable
final class TerminalManager {

    private var tmuxController: TmuxSessionController?
    private var activeTerminalView: LocalProcessTerminalView?
    private var currentCardID: UUID?

    var isLoading: Bool = false
    var error: String?
    var isTmuxAvailable: Bool = false

    init() {
        Task {
            await initialize()
        }
    }

    private func initialize() async {
        do {
            tmuxController = try await TmuxSessionController()
            isTmuxAvailable = true
        } catch {
            self.error = "tmux bulunamadi. Terminal ozelligi devre disi."
            isTmuxAvailable = false
        }
    }

    // MARK: - Public API

    /// Kart icin terminal view olustur veya getir
    @MainActor
    func terminalView(for cardID: UUID) async throws -> LocalProcessTerminalView {
        // Ayni kart icin mevcut view'i dondur
        if currentCardID == cardID, let existingView = activeTerminalView {
            return existingView
        }

        isLoading = true
        defer { isLoading = false }

        // Onceki terminal'i temizle
        await detachCurrentTerminal()

        // tmux session'i hazirla
        guard let controller = tmuxController else {
            throw TerminalError.tmuxNotAvailable
        }

        let sessionName = try await controller.ensureSession(forCardID: cardID)

        // Yeni terminal view olustur
        let terminalView = createTerminalView()

        // tmux session'a attach ol
        startTmuxAttach(terminalView: terminalView, sessionName: sessionName)

        activeTerminalView = terminalView
        currentCardID = cardID

        return terminalView
    }

    /// Mevcut terminal'i detach et
    @MainActor
    func detachCurrentTerminal() async {
        if let view = activeTerminalView {
            // Ctrl+B, D gonder (tmux detach)
            view.send(txt: "\u{02}d")  // Ctrl+B = 0x02

            // Process'i temiz kapat
            // Not: LocalProcessTerminalView process'i otomatik yonetir
        }

        activeTerminalView = nil
        currentCardID = nil
    }

    /// Tum session'lari temizle (uygulama kapatilirken)
    func cleanup() async {
        await detachCurrentTerminal()
        // Session'lari SILME - persist olmali
    }

    // MARK: - Private Helpers

    private func createTerminalView() -> LocalProcessTerminalView {
        let config = TerminalConfiguration()
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let terminalView = LocalProcessTerminalView(frame: frame)

        // Gorunum ayarlari
        terminalView.font = config.font
        terminalView.nativeBackgroundColor = config.backgroundColor
        terminalView.nativeForegroundColor = config.foregroundColor

        return terminalView
    }

    private func startTmuxAttach(terminalView: LocalProcessTerminalView, sessionName: String) {
        // tmux attach komutu baslat
        let tmuxPath = "/opt/homebrew/bin/tmux" // veya dinamik bul

        terminalView.startProcess(
            executable: tmuxPath,
            args: ["attach", "-t", sessionName],
            environment: nil,
            execName: nil
        )
    }
}

enum TerminalError: Error {
    case tmuxNotAvailable
    case sessionCreationFailed
}
```

---

## Adim 5: TerminalContainerView (NSViewRepresentable)

SwiftUI'de kullanmak icin wrapper view.

```swift
// Terminal/TerminalContainerView.swift

import SwiftUI
import SwiftTerm
import AppKit

struct TerminalContainerView: NSViewRepresentable {
    let cardID: UUID
    @Environment(TerminalManager.self) private var terminalManager

    @State private var terminalView: LocalProcessTerminalView?
    @State private var isLoading = true
    @State private var error: String?

    func makeNSView(context: Context) -> NSView {
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor

        Task { @MainActor in
            do {
                let view = try await terminalManager.terminalView(for: cardID)
                view.frame = containerView.bounds
                view.autoresizingMask = [.width, .height]
                containerView.addSubview(view)
                terminalView = view
                isLoading = false
            } catch {
                self.error = error.localizedDescription
                isLoading = false
            }
        }

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Boyut degisikliklerini handle et
        if let terminal = terminalView {
            terminal.frame = nsView.bounds
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // View kaldirildiginda cleanup
        // Terminal detach otomatik olarak TerminalManager tarafindan yapilir
    }
}
```

---

## Adim 6: CardDetailView Entegrasyonu

Mevcut CardDetailView'a terminal ekle.

```swift
// Mevcut CardDetailView.swift'e eklenecek degisiklikler

struct CardDetailView: View {
    let card: Card
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @Environment(TerminalManager.self) private var terminalManager

    // ... mevcut @State degiskenleri ...

    @State private var showTerminal = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mevcut kart bilgileri - scroll edilebilir alan
            ScrollView {
                cardInfoSection
                    .padding(20)
            }
            .frame(height: showTerminal ? 200 : nil)

            if showTerminal && terminalManager.isTmuxAvailable {
                Divider()

                // Terminal section
                VStack(spacing: 0) {
                    terminalHeader

                    TerminalContainerView(cardID: card.id)
                        .frame(minHeight: 200)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 500, maxWidth: 600)
        .background(Color.cardBackground)
    }

    private var cardInfoSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Mevcut card info icerigi buraya tasinir
            // (column badge, title, created date, move buttons)
        }
    }

    private var terminalHeader: some View {
        HStack {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Terminal")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: { showTerminal.toggle() }) {
                Image(systemName: showTerminal ? "chevron.down" : "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
    }
}
```

---

## Adim 7: App Entry Point Guncelleme

TerminalManager'i environment'a ekle.

```swift
// zenbanApp.swift

import SwiftUI

@main
struct zenbanApp: App {
    @State private var boardStore = BoardStore()
    @State private var terminalManager = TerminalManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(boardStore)
                .environment(terminalManager)
        }
        .commands {
            // Mevcut commands
        }
    }
}
```

---

## Adim 8: Performans Optimizasyonlari

### 8.1 Lazy Terminal Loading
Terminal sadece kart detayi acildiginda yuklenir.

### 8.2 Session Cleanup
Silinen kartlarin session'larini temizle:

```swift
// BoardStore.swift'e ekle

func deleteCard(_ cardID: UUID, from boardID: UUID) {
    // Mevcut silme mantigi

    // Terminal session'ini temizle
    Task {
        try? await TmuxSessionController().killSession("zenban_card_\(cardID.uuidString)")
    }
}
```

### 8.3 Memory Yonetimi
- Tek bir `LocalProcessTerminalView` instance tutulur
- Kart degistiginde tmux detach/attach yapilir
- View destroy edildiginde process temizlenir

---

## Adim 9: Entitlements ve Sandbox

macOS App Sandbox ile calisabilmek icin:

```xml
<!-- zenban.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <!-- Terminal icin gerekli -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
```

**Not**: Tam terminal erisimi icin sandbox kapatilmasi gerekebilir veya XPC service kullanilabilir.

---

## Adim 10: Test Plani

### 10.1 Unit Tests
- TmuxSessionController session CRUD operasyonlari
- TerminalManager state yonetimi

### 10.2 Integration Tests
- Kart acildiginda terminal baslatma
- Kart degistiginde session korunmasi
- Uygulama yeniden baslatildiginda session persistence

### 10.3 Manual Tests
- Terminal input/output
- Scrollback calisma durumu
- Copy/paste
- Resize handling

---

## Riskler ve Azaltma Stratejileri

| Risk | Olasilik | Etki | Azaltma |
|------|----------|------|---------|
| tmux kullanicida yok | Orta | Yuksek | Homebrew ile kurulum onerisi veya bundle etme |
| Sandbox kisitlamalari | Yuksek | Yuksek | Hardened Runtime kullan veya sandbox devre disi |
| Memory leak | Dusuk | Orta | Strict cleanup, detach protokolu |
| Focus handling | Orta | Dusuk | First responder yonetimi |

---

## Tahmini Is Yukleri

| Adim | Aciklama |
|------|----------|
| 1 | SwiftTerm entegrasyonu |
| 2 | TmuxSessionController |
| 3 | TerminalManager |
| 4 | NSViewRepresentable wrapper |
| 5 | CardDetailView entegrasyonu |
| 6 | Test ve debug |

---

## Referanslar

- [SwiftTerm GitHub](https://github.com/migueldeicaza/SwiftTerm)
- [tmux Wiki - Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- [tmux Wiki - Getting Started](https://github.com/tmux/tmux/wiki/Getting-Started)
- [Apple NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable)

---

## Onay

Bu plan onaylandiginda implementasyona baslanabilir.
