# GhosttyTerminalView - Missing Features from SwiftTerm

Bu dosya, SwiftTerm tabanlı `ZenbanTerminalView`'da mevcut olan ancak `GhosttyTerminalView`'da henuz implemente edilmemis ozellikleri listeler.

## 1. Agent State Machine

SwiftTerm'de terminal bir state machine ile yonetiliyor:

```
States:
- shell        -> Normal shell, agent calismiyor
- agentActive  -> Claude calisiyor, output izleniyor
- agentIdle    -> Task tamamlandi, kart "In Review" durumunda

Events:
- agentDetected   -> Input veya output'ta "claude" bulundu
- taskCompleted   -> 2 saniye output olmadi (idle)
- newMessageSent  -> Kullanici idle durumda yeni mesaj gonderdi
- agentExited     -> Ctrl+C basildi
```

**Ghostty'de eksik:** State machine tamamen yok.

---

## 2. Idle Detection (Bosta Kalma Tespiti)

SwiftTerm'de agent calisirken output izlenir:
- 2 saniye boyunca output gelmezse "idle" kabul edilir
- Minimum 10 byte aktivite gerekli
- `DispatchWorkItem` ile zamanlama yapiliyor

```swift
private var idleWorkItem: DispatchWorkItem?
private var activityByteCount: Int = 0
private let idleThreshold: TimeInterval = 2.0
private let minActivityBytes: Int = 10
```

**Ghostty'de eksik:** Output monitoring ve idle detection yok.

---

## 3. Agent Detection (Agent Tespiti)

SwiftTerm'de "claude" keywordu tespit ediliyor:
- Input buffer'da komut izleniyor
- Output buffer'da (500 char) keyword araniyor
- ANSI escape kodlari regex ile temizleniyor
- Ctrl+R history search destegi var

```swift
private var inputBuffer = ""
private var outputBuffer = ""
private let outputBufferMaxSize = 500
private var agentDetectedInOutput = false
private static let agentKeyword = "claude"
```

**Ghostty'de eksik:** Input/output buffering ve keyword detection yok.

---

## 4. Shell Readiness Tracking

SwiftTerm'de shell hazir olunca pending command gonderiliyor:

```swift
private(set) var isShellReady = false
private var pendingCommand: String?

func sendWhenReady(_ command: String) {
    if isShellReady {
        send(txt: command)
    } else {
        pendingCommand = command
    }
}
```

**Ghostty'de:** `isShellReady` ve `pendingCommand` tanimli ama `dataReceived` hook'u yok, bu yuzden shell readiness tespit edilemiyor.

---

## 5. Input Processing (Byte-Level)

SwiftTerm'de her input byte'i isleniyor:
- `0x03` (Ctrl+C) -> Agent exit
- `0x0D` (Enter) -> Komutu isle
- `0x7F` (Backspace) -> Buffer'dan sil
- Printable karakterler buffer'a ekleniyor

```swift
override func send(source: TerminalView, data: ArraySlice<UInt8>) {
    super.send(source: source, data: data)
    processInput(data)
}
```

**Ghostty'de eksik:** Input byte processing yok.

---

## 6. Notification Integration

SwiftTerm'de NotificationService ile entegrasyon:
- Task completed bildirimi
- Agent resumed bildirimi
- Card/Board context ile

```swift
private func sendNotification(title: String, body: String)
private func triggerTaskCompleted()
private func triggerAgentResumed()
```

**Ghostty'de eksik:** NotificationService entegrasyonu yok.

---

## 7. Focus Tracking

SwiftTerm'de terminal focus durumu izleniyor:

```swift
private var hasBeenFocused = false

override func becomeFirstResponder() -> Bool {
    let response = super.becomeFirstResponder()
    if response {
        hasBeenFocused = true
    }
    return response
}
```

**Ghostty'de:** `becomeFirstResponder` override var ama `hasBeenFocused` tracking yok.

---

## 8. Link Opening Prevention

SwiftTerm'de dev server linkleri engelleniyordu:

```swift
override func requestOpenLink(source: TerminalView, link: String, params: [String:String]) {
    // Do nothing - prevent dev server links from opening in external browser
}
```

**Ghostty'de eksik:** Link callback handling yok.

---

## Implementation Priority

| Feature | Priority | Complexity | Notes |
|---------|----------|------------|-------|
| Shell Readiness | High | Low | dataReceived hook gerekli |
| Input Processing | High | Medium | Byte-level monitoring |
| Agent Detection | Medium | Medium | Buffer management |
| State Machine | Medium | Medium | Event-driven |
| Idle Detection | Medium | Low | Timer-based |
| Notifications | Low | Low | Service call |
| Focus Tracking | Low | Low | Boolean flag |
| Link Prevention | Low | Low | Callback |

---

## Required Ghostty APIs

Implemente etmek icin gereken Ghostty C API fonksiyonlari:

1. **Output Callback** - Terminal output'u almak icin callback
2. **Input Interception** - Send edilen verileri yakalamak icin hook

Mevcut `ghostty_surface_key` ve `ghostty_surface_text` input icin kullaniliyor, ancak output icin bir callback mekanizmasi arastirilmali.
