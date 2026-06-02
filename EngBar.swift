import Cocoa
import SwiftUI
import Carbon.HIToolbox
import CoreAudio

// MARK: - Config
// Runtime config is read ONCE at launch from:
//     ~/Library/Application Support/EngBar/config.json
// Any missing field falls back to the defaults below, so the app still runs
// with zero config. This file holds the credential (apiKey) and the endpoint,
// and is intentionally NOT checked into source control — see config.example.json.
//
// config.json shape:
//   { "apiBase": "http://localhost:4001", "apiKey": "sk-...", "defaultModel": "claude-sonnet-4-6",
//     "eyeCareEnabled": true, "eyeWorkMinutes": 20, "eyeBreakSeconds": 60,
//     "eyeAutoCloseSeconds": 30, "eyeResetGapSeconds": 60 }
struct EngConfig: Decodable {
    var apiBase: String?
    var apiKey: String?
    var defaultModel: String?
    // 20-20-20 eye-care timer (all optional; omit to use defaults below)
    var eyeCareEnabled: Bool?
    var eyeWorkMinutes: Double?
    var eyeBreakSeconds: Double?
    var eyeAutoCloseSeconds: Double?
    var eyeResetGapSeconds: Double?
    var eyePopupIdleSkipSeconds: Double?   // idle ≥ this at break → red icon only, no popup

    static let shared: EngConfig = load()

    static func load() -> EngConfig {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return EngConfig()
        }
        let url = dir.appendingPathComponent("EngBar/config.json")
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(EngConfig.self, from: data) else {
            return EngConfig()
        }
        return cfg
    }
}

private let LLM_API_BASE = EngConfig.shared.apiBase ?? "http://localhost:4001"
let LLM_API = LLM_API_BASE + "/v1/messages"
let LLM_LIST_API = LLM_API_BASE + "/v1/models"
let LLM_KEY = EngConfig.shared.apiKey ?? "sk-123"
let LLM_DEFAULT_MODEL = EngConfig.shared.defaultModel ?? "claude-sonnet-4-6"

// Seed used when ~/Library/Application Support/EngBar/models.json is missing.
let LLM_FALLBACK_MODELS: [String] = [
    "claude-opus-4-5",
    "claude-sonnet-4-6",
    "claude-sonnet-4-5",
    "claude-haiku-4-5",
    "gpt-5",
    "gpt-5.1",
]

// MARK: - App Entry
@main
struct EngBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - Preference key for content height
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 30
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


// MARK: - Pasted image
struct PastedImage: Identifiable {
    let id = UUID()
    let data: Data        // PNG bytes
    let mediaType: String // e.g. "image/png"
    let nsImage: NSImage  // for thumbnail display
}

// MARK: - LRU Cache (20 entries)
class LRUCache {
    private var keys: [String] = []
    private var store: [String: String] = [:]
    private let capacity: Int

    init(capacity: Int = 20) {
        self.capacity = capacity
    }

    func get(_ key: String) -> String? {
        guard let value = store[key] else { return nil }
        // Move to end (most recently used)
        if let idx = keys.firstIndex(of: key) {
            keys.remove(at: idx)
            keys.append(key)
        }
        return value
    }

    func put(_ key: String, _ value: String) {
        if store[key] != nil {
            if let idx = keys.firstIndex(of: key) { keys.remove(at: idx) }
        } else if keys.count >= capacity {
            let oldest = keys.removeFirst()
            store.removeValue(forKey: oldest)
        }
        keys.append(key)
        store[key] = value
    }
}

// MARK: - KeyablePanel
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Hosting view that accepts the first mouse-down even when the panel isn't key,
// so a single click on empty bar areas (not buttons) registers the gesture.
class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var viewModel = BarViewModel()
    var eventMonitor: Any?
    var clickMonitor: Any?
    var eyeCare: EyeCareManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupEditMenu()
        setupStatusItem()
        eyeCare = EyeCareManager(app: self)   // created before the panel so BarView can observe it
        setupPanel()
        setupGlobalHotkey()
        setupClickOutsideMonitor()
        setupFocusObservers()
        showPanel()

        if EngConfig.shared.eyeCareEnabled ?? true {
            eyeCare.start()                   // disabled → stays dormant, remainingText == ""
        }
    }

    // Swap the menu-bar icon between normal and the red eye-care alert.
    // `closed` selects the blink frame (eye shut) for the flashing effect.
    func setEyeAlertIcon(_ on: Bool, closed: Bool = false) {
        statusItem?.button?.image = on ? makeEyeAlertIcon(closed: closed) : makeStatusIcon()
    }

    func setupFocusObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey),
            name: NSWindow.didResignKeyNotification, object: panel)

        // Intercept plain Enter inside our panel to submit.
        // Option+Enter and Shift+Enter both pass through as newlines.
        // Also intercept Cmd+V to capture pasted images.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.panel else { return event }

            // Cmd+V: try to capture image from pasteboard
            if event.keyCode == 9 && event.modifierFlags.contains(.command) {
                if self.tryCaptureImageFromPasteboard() {
                    return nil   // consumed: image was captured
                }
                return event     // text paste: let it through
            }

            // Readline-style shortcuts in the input box:
            //   Ctrl+U → delete everything from start of doc to caret
            //   Ctrl+W → delete word before caret
            if event.modifierFlags.contains(.control) {
                let kc = event.keyCode
                if (kc == 32 || kc == 13), let tv = self.focusedTextView() {
                    if kc == 32 {           // U
                        let caret = tv.selectedRange().location
                        tv.insertText("",
                                      replacementRange: NSRange(location: 0, length: caret))
                    } else {                // W
                        tv.deleteWordBackward(nil)
                    }
                    return nil
                }
            }

            // Enter handling
            if event.keyCode == 36 {
                // Option+Enter → pass through; macOS's native field-editor
                // handler turns it into a newline correctly.
                if event.modifierFlags.contains(.option) {
                    return event
                }
                // Shift+Enter → SwiftUI's TextField doesn't seem to route
                // this to a newline reliably, so we insert "\n" ourselves.
                if event.modifierFlags.contains(.shift) {
                    self.insertNewlineAtCaret()
                    return nil
                }
                // If IME is composing (Chinese/Japanese/Korean input has uncommitted text),
                // let Enter through so the IME can commit the candidate.
                if self.imeIsComposing() {
                    return event
                }
                DispatchQueue.main.async {
                    self.viewModel.submit { h in self.resizePanel(height: h) }
                }
                return nil
            }
            return event
        }
    }

    // Find the NSTextView that currently holds focus in our panel — either
    // the SwiftUI TextEditor's underlying view, or a TextField's field editor.
    private func focusedTextView() -> NSTextView? {
        let fr = panel.firstResponder
        if let tv = fr as? NSTextView { return tv }
        if let tf = fr as? NSTextField,
           let editor = tf.currentEditor() as? NSTextView { return editor }
        if let editor = panel.fieldEditor(false, for: nil) as? NSTextView { return editor }
        return nil
    }

    // Inserts "\n" at the current selection in the focused text editor.
    private func insertNewlineAtCaret() {
        guard let tv = focusedTextView() else { return }
        tv.insertText("\n", replacementRange: tv.selectedRange())
    }

    private func imeIsComposing() -> Bool {
        let fr = panel.firstResponder
        // Direct NSTextView
        if let tv = fr as? NSTextView, tv.hasMarkedText() {
            return true
        }
        // NSTextField with active editor
        if let tf = fr as? NSTextField,
           let editor = tf.currentEditor() as? NSTextView,
           editor.hasMarkedText() {
            return true
        }
        // Field editor of the window
        if let editor = panel.fieldEditor(false, for: nil) as? NSTextView,
           editor.hasMarkedText() {
            return true
        }
        // Walk the responder chain
        var responder: NSResponder? = fr
        while let r = responder {
            if let tv = r as? NSTextView, tv.hasMarkedText() {
                return true
            }
            responder = r.nextResponder
        }
        return false
    }

    private func tryCaptureImageFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        guard let image = NSImage(pasteboard: pb) else { return false }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        let pasted = PastedImage(data: pngData, mediaType: "image/png", nsImage: image)
        DispatchQueue.main.async {
            self.viewModel.pastedImages.append(pasted)
        }
        return true
    }

    @objc func panelBecameKey() {
        // handled by explicit button clicks / showPanel
    }

    @objc func panelResignedKey() {
        // The bar disappears entirely on blur; the menu-bar icon brings it
        // back. Output and conversation state are preserved across hide/show.
        panel.orderOut(nil)
    }

    private let barWidth: CGFloat = 600   // was 500; 1.2× wider

    private func clampToScreen(_ frame: inout NSRect) {
        guard let screen = NSScreen.main else { return }
        let s = screen.frame
        if frame.origin.x < s.minX { frame.origin.x = s.minX }
        if frame.origin.x + frame.size.width > s.maxX {
            frame.origin.x = s.maxX - frame.size.width
        }
    }

    func setupEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = makeStatusIcon()
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    private func makeStatusIcon(alert: Bool = false) -> NSImage {
        if alert { return makeEyeAlertIcon(closed: false) }
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let context = NSGraphicsContext.current?.cgContext

            // Draw a rounded rectangle (chat bubble base)
            let bubbleRect = NSRect(x: 1, y: 2, width: 18, height: 13)
            let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 4, yRadius: 4)
            NSColor.labelColor.setFill()
            bubblePath.fill()

            // Draw a small "tail" on the bubble (bottom-left)
            let tailPath = NSBezierPath()
            tailPath.move(to: NSPoint(x: 4, y: 3))
            tailPath.line(to: NSPoint(x: 2, y: 0))
            tailPath.line(to: NSPoint(x: 7, y: 3))
            tailPath.close()
            tailPath.fill()

            // Punch out a sparkle (★) in the bubble using the windowBackgroundColor (acts as transparency)
            context?.setBlendMode(.destinationOut)
            let sparklePath = NSBezierPath()
            let cx: CGFloat = 10, cy: CGFloat = 8.5
            // 4-point sparkle (diamond + cross)
            let pts: [(CGFloat, CGFloat)] = [
                (cx, cy + 4),     // top
                (cx + 1.5, cy + 1.5),
                (cx + 4, cy),     // right
                (cx + 1.5, cy - 1.5),
                (cx, cy - 4),     // bottom
                (cx - 1.5, cy - 1.5),
                (cx - 4, cy),     // left
                (cx - 1.5, cy + 1.5)
            ]
            sparklePath.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
            for p in pts.dropFirst() {
                sparklePath.line(to: NSPoint(x: p.0, y: p.1))
            }
            sparklePath.close()
            NSColor.black.setFill()
            sparklePath.fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    // Eye-care break icon on a bright neon-yellow block (hazard yellow+red,
    // stands out sharply in the menu bar). Two frames — open / closed — toggled
    // on a timer to make the eye blink. NOT a template image, so colors show.
    private func makeEyeAlertIcon(closed: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let neon  = NSColor(calibratedRed: 0.93, green: 1.0, blue: 0.0, alpha: 1)   // highlighter yellow
            let red   = NSColor(calibratedRed: 0.92, green: 0.05, blue: 0.05, alpha: 1) // iris
            let white = NSColor.white
            let ink   = NSColor(calibratedWhite: 0.10, alpha: 1)

            // Neon-yellow rounded background block.
            neon.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 18, height: 16),
                         xRadius: 4, yRadius: 4).fill()

            let cx: CGFloat = 10, cy: CGFloat = 9

            if closed {
                // Blink frame: a fat closed eyelid with two short lashes.
                let lid = NSBezierPath()
                lid.lineWidth = 2.0
                lid.lineCapStyle = .round
                lid.move(to: NSPoint(x: cx - 6.5, y: cy + 0.5))
                lid.curve(to: NSPoint(x: cx + 6.5, y: cy + 0.5),
                          controlPoint1: NSPoint(x: cx - 2, y: cy - 2.8),
                          controlPoint2: NSPoint(x: cx + 2, y: cy - 2.8))
                ink.setStroke(); lid.stroke()
                for dx in [-4.0, 0.0, 4.0] as [CGFloat] {
                    let l = NSBezierPath()
                    l.lineWidth = 1.4; l.lineCapStyle = .round
                    l.move(to: NSPoint(x: cx + dx * 0.8, y: cy - 2.0))
                    l.line(to: NSPoint(x: cx + dx, y: cy - 4.2))
                    ink.setStroke(); l.stroke()
                }
            } else {
                // Open frame: a full almond with a big red iris (饱满).
                let w: CGFloat = 7.5, h: CGFloat = 4.6
                let eye = NSBezierPath()
                eye.move(to: NSPoint(x: cx - w, y: cy))
                eye.curve(to: NSPoint(x: cx + w, y: cy),
                          controlPoint1: NSPoint(x: cx - 3.5, y: cy + h),
                          controlPoint2: NSPoint(x: cx + 3.5, y: cy + h))
                eye.curve(to: NSPoint(x: cx - w, y: cy),
                          controlPoint1: NSPoint(x: cx + 3.5, y: cy - h),
                          controlPoint2: NSPoint(x: cx - 3.5, y: cy - h))
                eye.close()
                white.setFill(); eye.fill()          // sclera fills the almond

                let ir: CGFloat = 4.2                 // big iris → 饱满
                red.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - ir, y: cy - ir, width: 2 * ir, height: 2 * ir)).fill()
                let pr: CGFloat = 1.7
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - pr, y: cy - pr, width: 2 * pr, height: 2 * pr)).fill()

                eye.lineWidth = 1.2; ink.setStroke(); eye.stroke()   // crisp outline
            }
            return true
        }
        image.isTemplate = false   // keep the colors
        return image
    }

    func setupPanel() {
        let content = BarView(viewModel: viewModel, eyeCare: eyeCare)
        let hostingView = FirstMouseHostingView(rootView: content)

        // Fixed bar height: TextEditor (93) + paddings + border ≈ 107.
        // Two rows of buttons live next to the input within its 100pt frame,
        // so bar height = input + paddings.
        let barHeight: CGFloat = 114
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Background-drag is fine: NSTextField / NSTextView report
        // mouseDownCanMoveWindow=false themselves, so drags inside the input
        // and output panel are still received as text selection. Drags on the
        // gray bar chrome / collapsed mini-bar move the window.
        panel.isMovableByWindowBackground = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Flush to absolute top of screen
        positionAtTop()
    }

    func setupClickOutsideMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            let screenPoint = NSEvent.mouseLocation
            if !self.panel.frame.contains(screenPoint) {
                DispatchQueue.main.async {
                    self.panel.orderOut(nil)
                }
            }
        }
    }

    func setupGlobalHotkey() {
        // Option + Space to toggle
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.option) && event.keyCode == 49 { // 49 = space
                DispatchQueue.main.async {
                    self?.togglePanel()
                }
            }
        }
        // Also local monitor for when app is focused
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.option) && event.keyCode == 49 {
                DispatchQueue.main.async {
                    self?.togglePanel()
                }
                return nil
            }
            return event
        }
    }

    @objc func togglePanel() {
        // Always show (don't toggle) — clicking the menu icon brings the bar forward
        showPanel()
    }

    func positionAtTop() {
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - panel.frame.width / 2
        let y = screen.frame.maxY - panel.frame.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showPanel() {
        // Ensure the bar's width is the canonical 500 each time we resurface
        // it — the panel may have been resized horizontally somehow.
        var frame = panel.frame
        if frame.size.width != barWidth {
            let centerX = frame.origin.x + frame.size.width / 2
            frame.size.width = barWidth
            frame.origin.x = centerX - barWidth / 2
            clampToScreen(&frame)
            panel.setFrame(frame, display: false, animate: false)
        }
        panel.makeKeyAndOrderFront(nil)
        positionAtTop()
        NSApp.activate(ignoringOtherApps: true)
        // Re-show the result dropdown if there's content waiting from a prior session.
        if viewModel.isLoading || !viewModel.output.isEmpty {
            viewModel.showOutput = true
            resizePanel(height: 394)  // fixed bar (90) + output (280)
        }
        // Focus input — small delay so SwiftUI re-renders before grabbing focus.
        viewModel.focusInput = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.viewModel.focusInput = true
        }
    }

    func resizePanel(height: CGFloat) {
        let newHeight = max(24, min(height, 520))
        let x = panel.frame.origin.x  // preserve user's horizontal position
        // Keep top edge of panel anchored at its current top
        let oldTopY = panel.frame.origin.y + panel.frame.size.height
        let y = oldTopY - newHeight
        let newFrame = NSRect(x: x, y: y, width: panel.frame.width, height: newHeight)
        panel.setFrame(newFrame, display: true, animate: true)
    }
}

// MARK: - ViewModel
class BarViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var output: String = ""
    @Published var isLoading: Bool = false
    @Published var showOutput: Bool = false
    @Published var focusInput: Bool = false
    @Published var pastedImages: [PastedImage] = []
    // Persisted across launches via UserDefaults.
    @Published var model: String = UserDefaults.standard.string(forKey: "engbar.model") ?? LLM_DEFAULT_MODEL {
        didSet { UserDefaults.standard.set(model, forKey: "engbar.model") }
    }
    // Available models — loaded from disk, refreshed from /v1/models on demand.
    @Published var models: [String] = []
    @Published var isRefreshingModels: Bool = false

    init() {
        if let cached = Self.loadModelsFromDisk(), !cached.isEmpty {
            self.models = cached
        } else {
            self.models = LLM_FALLBACK_MODELS
            // First launch (or stale/empty cache): fetch in the background.
            DispatchQueue.main.async { [weak self] in self?.refreshModels() }
        }
        // If the persisted pick has been filtered out (e.g. user previously had
        // gpt-5-mini and we now exclude minis), fall back to the default.
        if !self.models.contains(self.model) {
            self.model = self.models.contains(LLM_DEFAULT_MODEL)
                ? LLM_DEFAULT_MODEL
                : (self.models.first ?? LLM_DEFAULT_MODEL)
        }
    }

    // MARK: Models persistence

    private static var modelsFileURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("EngBar")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("models.json")
    }

    private static func loadModelsFromDisk() -> [String]? {
        guard let url = modelsFileURL,
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        // Re-apply the policy filter on read so stale caches don't leak excluded models.
        let cleaned = filterAndSort(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func saveModelsToDisk(_ list: [String]) {
        guard let url = modelsFileURL,
              let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url)
    }

    func refreshModels() {
        guard !isRefreshingModels else { return }
        guard let url = URL(string: LLM_LIST_API) else { return }
        isRefreshingModels = true

        var req = URLRequest(url: url)
        req.setValue("Bearer \(LLM_KEY)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRefreshingModels = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let arr = json["data"] as? [[String: Any]] else { return }
                let ids = arr.compactMap { $0["id"] as? String }
                let filtered = Self.filterAndSort(ids)
                guard !filtered.isEmpty else { return }
                self.models = filtered
                // If the user's previous pick is no longer offered, fall back gracefully.
                if !filtered.contains(self.model) {
                    self.model = filtered.contains(LLM_DEFAULT_MODEL) ? LLM_DEFAULT_MODEL : filtered[0]
                }
                Self.saveModelsToDisk(filtered)
            }
        }.resume()
    }

    private static func filterAndSort(_ ids: [String]) -> [String] {
        func family(_ id: String) -> Int {
            if id.hasPrefix("claude-") { return 0 }
            if id.hasPrefix("gpt-")    { return 1 }
            if id.hasPrefix("gemini-") { return 2 }
            return -1
        }
        // Excluded: anything in the gpt-4 family, plus "mini" / "nano" variants.
        func excluded(_ id: String) -> Bool {
            if id.hasPrefix("gpt-4") { return true }
            if id.contains("mini") || id.contains("nano") { return true }
            return false
        }
        let kept = Array(Set(ids)).filter { family($0) >= 0 && !excluded($0) }
        return kept.sorted { a, b in
            let fa = family(a), fb = family(b)
            if fa != fb { return fa < fb }
            return a < b
        }
    }

    private var streamTask: URLSessionDataTask?
    private var conversationHistory: [[String: Any]] = []
    private var lastSystem: String = ""
    private var lastAssistantReply: String = ""
    private var llmCache = LRUCache(capacity: 20)
    // Wall time of the most recently completed generation. If the user submits
    // again >10 minutes after this, a fresh session is started automatically.
    var lastGenerateTime: Date?
    private let sessionTimeout: TimeInterval = 600  // 10 min

    // Retry state for the in-flight stream
    private var pendingRequest: URLRequest?
    private var pendingCacheKey: String?
    private var pendingRetry: DispatchWorkItem?
    private var retriesLeft: Int = 0
    private let maxRetries: Int = 1   // 1 retry → up to 2 attempts total
    private let retryDelay: TimeInterval = 1.0

    // TTFT instrumentation:
    //   submitTime  — when the user hit Enter (covers app overhead + request)
    //   requestTime — when URLSession.dataTask.resume() was called for the
    //                 (possibly-retried) request that produced the first token
    // On the first streamed token we echo both diffs as an italic line.
    var submitTime: Date?
    var requestTime: Date?
    var firstTokenEchoed: Bool = false

    // The last text the user submitted (including any "/" prefix) — used by
    // the retry button to re-ask the same question.
    var lastUserText: String?

    // Bumps each time the user submits a new question. MarkdownView watches
    // it and on change scrolls the NSTextView so the newly-appended user
    // question sits at the top of the visible area.
    @Published var scrollPinTick: Int = 0

    enum LLMMode {
        case newChat
        case continueChat
        case corrector       // one-shot: polish non-native English (2 versions)
        case etymology       // one-shot: explain word origins
        case explain         // one-shot: decode a hard English sentence
    }

    // For one-shot tool modes, wrap the user's text with an instruction
    // template so the assistant's reply enters the conversation as a normal
    // user/assistant turn. The user can then follow up with multi-turn chat.
    private static func wrappedUserContent(for mode: LLMMode, text: String) -> String? {
        let body: String
        switch mode {
        case .corrector:
            body = """
            请按下面要求处理 <user-input> 中的英文文本，输出**两个**版本：

            **✏️ Edited（轻量改正 / 老师改作文）**
            紧扣原句结构，只修正用词不当、表达不当、语法 / 拼写 / 标点错误；
            遇到中文片段，替换成最贴近原意的英语；其余尽量保留学生原措辞。
            紧跟一条简短的中文 markdown bullet 列表，写主要改动 → 简要说明。

            **🌐 Native（母语者地道版）**
            从母语者角度自然地表达同一个意思，可以重组句子、换措辞、换结构；
            遇到中文同样换成地道的英文表达。
            紧跟一条简短的中文 markdown bullet 列表，写思路 / 表达点。

            说明用中文，简短到位。不要罗列所有 trivial 的拼写。如果原文已经地道，\
            回 "Looks good!" 就停下，不要凑词。
            """
        case .explain:
            body = """
            请解读 <user-input> 中的英语（一句或一小段），用中文 markdown 输出：

            **📖 句意** —— 整段的中文翻译，简洁通顺，能表达原文语气。

            **🔍 难点**
            - 超出中学水平的语法 / 句式 / 复杂从句 / 倒装 / 虚拟语气等，每点一两句解释
            - 重点关注不常见 / 容易被误解的用法

            **🧩 关键词 / 短语**
            - **word/phrase** —— 释义；如果是习语、固定搭配、文化典故、双关，明确点出

            全程中文。如果整段很简单没什么难点，直接说"无超纲点"并给翻译即可。
            """
        case .etymology:
            body = """
            请针对 <user-input> 中的英语单词，用简洁的中文 markdown 解释：

            1. 来源语言和原始词根形式
            2. 原始含义
            3. 含义如何演变到现代用法
            4. 列出 3–5 个共享同一词根的现代英语单词，每个加一行简短释义

            全程中文输出。
            """
        case .newChat, .continueChat:
            return nil
        }
        return """
        <user-input>
        \(text)
        </user-input>

        \(body)
        """
    }

    func submit(mode forcedMode: LLMMode? = nil,
                resizer: @escaping (CGFloat) -> Void) {
        let text = input.trimmingCharacters(in: .whitespaces)
        // Empty input + no images → just wait
        guard !text.isEmpty || !pastedImages.isEmpty else { return }

        // "/" prefix → force a fresh session. Otherwise default to continue.
        var actualText = text
        var forceNewSession = false
        if text.hasPrefix("/") {
            actualText = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            forceNewSession = true
        }

        if actualText.isEmpty && pastedImages.isEmpty { return }

        // Resolve final mode. Caller-forced overrides everything; otherwise
        // auto-new-session if more than `sessionTimeout` seconds have passed
        // since the last generation, or there's no prior history.
        let mode: LLMMode
        if let m = forcedMode {
            mode = m
        } else {
            let stale = lastGenerateTime.map { Date().timeIntervalSince($0) > sessionTimeout } ?? true
            mode = (forceNewSession || conversationHistory.isEmpty || stale)
                ? .newChat : .continueChat
        }

        submitTime = Date()
        firstTokenEchoed = false
        lastUserText = text   // remember the raw text (incl. "/" prefix) for retry

        isLoading = true
        showOutput = true
        resizer(394)   // fixed bar (90) + output (280)
        callLLM(text: actualText, mode: mode)

        // Signal MarkdownView to scroll the new user question to the top once
        // the next layout pass runs. Bump AFTER callLLM has appended the
        // userHeader to `output` so the rendered text contains the new "🧑 ".
        scrollPinTick &+= 1
    }

    // Re-submit the most recent user message. Re-uses submit() so the prefix
    // ("/" forcing a new session) and 10-min stale logic still apply.
    func retry(resizer: @escaping (CGFloat) -> Void) {
        guard let text = lastUserText, !isLoading else { return }
        input = text
        submit(resizer: resizer)
    }

    // User-initiated cancellation of the in-flight stream. Cancels the
    // URLSession task (which cascades to didCompleteWithError → isLoading=false
    // via the cancellation branch) and any queued retry, plus a tiny marker
    // in the output so the cutoff is visible.
    func stop() {
        guard isLoading else { return }
        output += "\n\n*[stopped]*"
        streamTask?.cancel()
        pendingRetry?.cancel()
        pendingRetry = nil
    }

    func reset() {
        streamTask?.cancel()
        pendingRetry?.cancel()
        pendingRetry = nil
        pendingRequest = nil
        pendingCacheKey = nil
        retriesLeft = 0
        input = ""
        output = ""
        isLoading = false
        showOutput = false
        pastedImages = []
        conversationHistory = []
        lastAssistantReply = ""
        lastGenerateTime = nil
    }

    // MARK: LLM Streaming
    private func callLLM(text actualText: String, mode: LLMMode) {
        let isContinue = (mode == .continueChat)
        let hasImages = !pastedImages.isEmpty
        let activeModel = model

        // System prompt is always the generic helpful-assistant. For one-shot
        // tools (corrector / explain / etymology) the actual instruction is
        // wrapped INTO the user message instead — so the assistant's reply
        // lands in conversationHistory as a normal turn and the user can
        // follow up with further questions in regular continue-chat mode.
        let system: String
        if hasImages {
            system = "You are a helpful assistant. Examine the provided image(s) and respond to the user. Use markdown formatting when appropriate."
        } else {
            system = "You are a helpful assistant. Answer concisely. Use markdown formatting when appropriate."
        }

        // Build user request header for transcript display.
        // <USER>...</USER> is a custom marker the native MarkdownView renders as a colored bubble.
        var userHeader = "<USER>\(actualText)</USER>"
        if hasImages {
            userHeader += "\n\n*\(pastedImages.count) image\(pastedImages.count > 1 ? "s" : "") attached*"
        }
        userHeader += "\n\n"

        if isContinue && !output.isEmpty {
            output += "\n\n---\n\n" + userHeader
        } else {
            output = userHeader
        }

        // Cache check (skip for continue + image messages). Cache key includes model.
        let cacheKey = "\(mode)::\(activeModel)::\(actualText)"
        if !isContinue && !hasImages {
            if let cached = llmCache.get(cacheKey) {
                output += cached
                isLoading = false
                lastGenerateTime = Date()
                lastSystem = system
                lastAssistantReply = cached
                conversationHistory = [
                    ["role": "user", "content": actualText],
                    ["role": "assistant", "content": cached]
                ]
                return
            }
        }

        // Build user content (text + images if any). For one-shot tool modes
        // we wrap the user's text in an XML envelope + instruction so the
        // assistant treats it as a normal Q/A turn that supports follow-up.
        let textForLLM = Self.wrappedUserContent(for: mode, text: actualText) ?? actualText
        let userContent: Any
        if hasImages {
            var contentBlocks: [[String: Any]] = pastedImages.map { img in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": img.mediaType,
                        "data": img.data.base64EncodedString()
                    ]
                ]
            }
            let combined = textForLLM.isEmpty ? "What do you see in this image?" : textForLLM
            contentBlocks.append(["type": "text", "text": combined])
            userContent = contentBlocks
        } else {
            userContent = textForLLM
        }

        // Manage conversation history (use lastAssistantReply, not the HTML-laden output)
        if isContinue && !conversationHistory.isEmpty {
            if !lastAssistantReply.isEmpty {
                conversationHistory.append(["role": "assistant", "content": lastAssistantReply])
            }
            conversationHistory.append(["role": "user", "content": userContent])
        } else {
            conversationHistory = [["role": "user", "content": userContent]]
            lastSystem = system
        }
        lastAssistantReply = ""

        guard let url = URL(string: LLM_API) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(LLM_KEY, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // No-bytes-received timeout. 30s is enough for a healthy stream; if
        // we go 30s without any new bytes the connection is almost certainly
        // stuck and we should give up + retry.
        request.timeoutInterval = 30

        // Anthropic prompt caching: mark the LAST message with
        // cache_control:ephemeral so the prefix (system + all prior turns +
        // this turn) becomes a cache checkpoint. Subsequent follow-up
        // requests can reuse the cached prefix instead of re-processing it.
        // String content needs to be wrapped in a text content block since
        // cache_control only applies at the block level.
        var messagesOut = conversationHistory
        if !messagesOut.isEmpty {
            var last = messagesOut[messagesOut.count - 1]
            if let s = last["content"] as? String {
                last["content"] = [[
                    "type": "text",
                    "text": s,
                    "cache_control": ["type": "ephemeral"]
                ] as [String: Any]]
            } else if var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
                blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
                last["content"] = blocks
            }
            messagesOut[messagesOut.count - 1] = last
        }
        let body: [String: Any] = [
            "model": activeModel,
            "max_tokens": 8000,
            "stream": true,
            "system": isContinue ? lastSystem : system,
            "messages": messagesOut
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Only store in cache for fresh non-image sessions
        let storeCacheKey: String? = (isContinue || hasImages) ? nil : cacheKey
        startStream(request: request, cacheKey: storeCacheKey, fresh: true)

        // Clear input + images after submit (they're in history now)
        input = ""
        pastedImages = []
    }

    private func startStream(request: URLRequest, cacheKey: String?, fresh: Bool) {
        // Clean slate for a brand-new request
        if fresh {
            streamTask?.cancel()
            pendingRetry?.cancel()
            pendingRetry = nil
            pendingRequest = request
            pendingCacheKey = cacheKey
            retriesLeft = maxRetries
        }
        let session = URLSession(configuration: .default,
                                 delegate: StreamDelegate(viewModel: self),
                                 delegateQueue: nil)
        streamTask = session.dataTask(with: request)
        requestTime = Date()
        streamTask?.resume()
    }

    func handleStreamSuccess() {
        isLoading = false
        lastGenerateTime = Date()
        if let key = pendingCacheKey, !output.isEmpty {
            llmCache.put(key, output)
        }
        pendingRequest = nil
        pendingCacheKey = nil
        retriesLeft = 0
    }

    func handleStreamFailure(message: String) {
        if retriesLeft > 0, let req = pendingRequest {
            retriesLeft -= 1
            // Trailing \n\n keeps the retry banner in its own markdown block so
            // it doesn't fuse with whatever the retry appends next (TTFT echo,
            // tokens, or a second error).
            output += "\n\n*[Error: \(message) — retrying in \(Int(retryDelay))s…]*\n\n"
            let item = DispatchWorkItem { [weak self] in
                self?.startStream(request: req, cacheKey: self?.pendingCacheKey, fresh: false)
            }
            pendingRetry = item
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: item)
        } else {
            output += "\n\n*[Error: \(message)]*"
            isLoading = false
            pendingRequest = nil
            pendingCacheKey = nil
        }
    }

    func cacheResult(key: String, value: String) {
        llmCache.put(key, value)
    }

    func appendToLastReply(_ token: String) {
        lastAssistantReply += token
    }
}

// MARK: - Stream Delegate
class StreamDelegate: NSObject, URLSessionDataDelegate {
    weak var viewModel: BarViewModel?
    private var buffer = Data()
    private var bodyBuffer = Data()
    private var httpStatus: Int = 200

    // Captured from message_start (model id used server-side + initial
    // token counts) and updated from message_delta (final output_tokens).
    private var actualModel: String?
    private var inputTokens: Int?         // fresh prefill, not from cache
    private var cacheReadTokens: Int?     // reused from cache
    private var cacheWriteTokens: Int?    // freshly written to cache
    private var outputTokens: Int?

    init(viewModel: BarViewModel) {
        self.viewModel = viewModel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpStatus = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Non-2xx responses → accumulate body for the error report instead of parsing as SSE.
        if !(200...299).contains(httpStatus) {
            bodyBuffer.append(data)
            return
        }

        buffer.append(data)

        // Locate the last LF (0x0A) at the byte level — SSE always uses \n as
        // a line terminator, and \n is single-byte in UTF-8 so this never
        // falls inside a multi-byte character. Everything up to and including
        // that LF is "complete lines"; the rest stays in buffer.
        let newline: UInt8 = 0x0A
        let lastNL = buffer.lastIndex(of: newline)
        guard let lastNL = lastNL else { return }   // no full line yet

        // buffer.startIndex is 0 for a fresh Data, but Data subscripting uses
        // absolute indices that can be non-zero after slicing — be safe.
        let completeData = buffer.subdata(in: buffer.startIndex..<(lastNL + 1))
        let tailData     = buffer.subdata(in: (lastNL + 1)..<buffer.endIndex)
        buffer = tailData

        guard let completeText = String(data: completeData, encoding: .utf8) else { return }
        // dropLast() because text ends in \n so the final split is ""
        let completeLines = completeText.components(separatedBy: "\n").dropLast()

        for line in completeLines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { continue }
            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "message_start":
                // First event of the stream — carries the actual model id the
                // server picked and the initial input/cache token counts.
                if let msg = json["message"] as? [String: Any] {
                    self.actualModel = msg["model"] as? String
                    if let u = msg["usage"] as? [String: Any] {
                        self.inputTokens      = u["input_tokens"] as? Int
                        self.cacheReadTokens  = u["cache_read_input_tokens"] as? Int
                        self.cacheWriteTokens = u["cache_creation_input_tokens"] as? Int
                        self.outputTokens     = u["output_tokens"] as? Int
                    }
                }
                continue

            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any],
                      let token = delta["text"] as? String else { continue }
                DispatchQueue.main.async {
                    if let vm = self.viewModel, !vm.firstTokenEchoed {
                        vm.firstTokenEchoed = true
                        let now = Date()
                        let userMs = vm.submitTime.map {
                            Int((now.timeIntervalSince($0) * 1000).rounded())
                        }
                        let reqMs = vm.requestTime.map {
                            Int((now.timeIntervalSince($0) * 1000).rounded())
                        }
                        // Echoed in the panel only; NOT fed back into the assistant
                        // reply / conversation history.
                        if let u = userMs, let r = reqMs {
                            vm.output += "\n\n*⏱ user (\(Self.fmtMs(u))) · req (\(Self.fmtMs(r)))*\n\n"
                        }
                    }
                    self.viewModel?.output += token
                    self.viewModel?.appendToLastReply(token)
                }

            case "message_delta":
                // Carries final output_tokens count + stop_reason.
                if let u = json["usage"] as? [String: Any],
                   let out = u["output_tokens"] as? Int {
                    self.outputTokens = out
                }
                // Anything other than end_turn is worth surfacing so partial
                // output is explained.
                if let delta = json["delta"] as? [String: Any],
                   let stop = delta["stop_reason"] as? String,
                   stop != "end_turn",
                   stop != "stop_sequence" {
                    let label: String
                    switch stop {
                    case "max_tokens": label = "output truncated — max tokens reached"
                    case "tool_use":   label = "stopped for tool use"
                    case "refusal":    label = "model refused to continue"
                    default:           label = "stopped (\(stop))"
                    }
                    DispatchQueue.main.async {
                        self.viewModel?.output += "\n\n*[\(label)]*"
                    }
                }

            case "error":
                if let err = json["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    DispatchQueue.main.async {
                        self.viewModel?.output += "\n\n*[server error: \(msg)]*"
                    }
                }

            default:
                continue   // message_start, content_block_start, ping, etc.
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            // Cancellation = user-initiated, no retry, no error UI
            if let err = error, (err as NSError).code == NSURLErrorCancelled {
                self.viewModel?.isLoading = false
                return
            }
            // Transport error (timeout, no network, dns, etc.)
            if let err = error {
                self.viewModel?.handleStreamFailure(message: self.transportMessage(err))
                return
            }
            // HTTP-level error (4xx/5xx)
            if !(200...299).contains(self.httpStatus) {
                let snippet = self.bodySnippet()
                let msg = snippet.isEmpty ? "HTTP \(self.httpStatus)" : "HTTP \(self.httpStatus): \(snippet)"
                self.viewModel?.handleStreamFailure(message: msg)
                return
            }
            // Success — append a usage footer so the user sees the actual
            // model the server used + token breakdown (prefill / cache /
            // output).
            self.appendUsageFooter()
            self.viewModel?.handleStreamSuccess()
        }
    }

    private func appendUsageFooter() {
        guard let vm = self.viewModel else { return }
        var parts: [String] = []
        if let m = actualModel { parts.append(m) }
        if let n = inputTokens      { parts.append("prefill=\(n)") }
        if let n = cacheReadTokens,  n > 0 { parts.append("cache-hit=\(n)") }
        if let n = cacheWriteTokens, n > 0 { parts.append("cache-write=\(n)") }
        if let n = outputTokens     { parts.append("out=\(n)") }
        guard !parts.isEmpty else { return }
        vm.output += "\n\n*📊 \(parts.joined(separator: " · "))*"
    }

    static func fmtMs(_ ms: Int) -> String {
        // Anything ≥ 1s shows as integer seconds; sub-second stays in ms.
        if ms >= 1000 {
            return "\(Int((Double(ms) / 1000.0).rounded()))s"
        }
        return "\(ms)ms"
    }

    private func transportMessage(_ error: Error) -> String {
        let nsErr = error as NSError
        switch nsErr.code {
        case NSURLErrorTimedOut:               return "request timeout"
        case NSURLErrorCannotConnectToHost:    return "cannot connect to host"
        case NSURLErrorCannotFindHost:         return "cannot find host"
        case NSURLErrorNotConnectedToInternet: return "no internet"
        case NSURLErrorNetworkConnectionLost:  return "connection lost"
        case NSURLErrorDNSLookupFailed:        return "DNS lookup failed"
        default:                               return error.localizedDescription
        }
    }

    private func bodySnippet() -> String {
        guard !bodyBuffer.isEmpty,
              let s = String(data: bodyBuffer, encoding: .utf8) else { return "" }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let maxLen = 200
        let snippet = trimmed.count > maxLen ? String(trimmed.prefix(maxLen)) + "…" : trimmed
        return snippet.replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Native Markdown View (no WebKit)

enum MdBlock {
    case userMsg(String)
    case heading(Int, String)
    case paragraph(String)
    case codeBlock(String)
    case hr
    case list([String], Bool)   // items, ordered
    case blockquote(String)
    case table([String], [[String]])  // headers, rows
}

private func splitTableRow(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s = String(s.dropFirst()) }
    if s.hasSuffix("|") { s = String(s.dropLast()) }
    return s.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

private func looksLikeTableSeparator(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("|"), t.hasSuffix("|"), t.count > 2 else { return false }
    let inner = String(t.dropFirst().dropLast())
    let allowed: Set<Character> = ["-", ":", "|", " "]
    return inner.allSatisfy { allowed.contains($0) } && inner.contains("-")
}

func parseMarkdownBlocks(_ md: String) -> [MdBlock] {
    var blocks: [MdBlock] = []
    let lines = md.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let raw = lines[i]
        let trim = raw.trimmingCharacters(in: .whitespaces)
        if trim.isEmpty { i += 1; continue }

        // <USER>...</USER> bubble (possibly multi-line)
        if raw.hasPrefix("<USER>") {
            var content = String(raw.dropFirst("<USER>".count))
            if let r = content.range(of: "</USER>") {
                content = String(content[..<r.lowerBound])
                blocks.append(.userMsg(content))
                i += 1
                continue
            }
            i += 1
            while i < lines.count {
                if let r = lines[i].range(of: "</USER>") {
                    content += "\n" + String(lines[i][..<r.lowerBound])
                    i += 1
                    break
                }
                content += "\n" + lines[i]
                i += 1
            }
            blocks.append(.userMsg(content))
            continue
        }

        if trim == "---" || trim == "***" || trim == "___" {
            blocks.append(.hr); i += 1; continue
        }

        if trim.hasPrefix("### ") { blocks.append(.heading(3, String(trim.dropFirst(4)))); i += 1; continue }
        if trim.hasPrefix("## ")  { blocks.append(.heading(2, String(trim.dropFirst(3)))); i += 1; continue }
        if trim.hasPrefix("# ")   { blocks.append(.heading(1, String(trim.dropFirst(2)))); i += 1; continue }

        // fenced code block ```lang ... ```
        if trim.hasPrefix("```") {
            i += 1
            var code = ""
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !code.isEmpty { code += "\n" }
                code += lines[i]
                i += 1
            }
            if i < lines.count { i += 1 }
            blocks.append(.codeBlock(code))
            continue
        }

        // unordered list
        if trim.hasPrefix("- ") || trim.hasPrefix("* ") {
            var items: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ")      { items.append(String(t.dropFirst(2))) }
                else if t.hasPrefix("* ") { items.append(String(t.dropFirst(2))) }
                else { break }
                i += 1
            }
            blocks.append(.list(items, false))
            continue
        }

        // ordered list "1. text"
        if trim.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
            var items: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if let r = t.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                    items.append(String(t[r.upperBound...]))
                } else { break }
                i += 1
            }
            blocks.append(.list(items, true))
            continue
        }

        // blockquote
        if trim.hasPrefix("> ") {
            var quote = String(trim.dropFirst(2))
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("> ") { quote += "\n" + String(t.dropFirst(2)); i += 1 }
                else { break }
            }
            blocks.append(.blockquote(quote))
            continue
        }

        // table: |a|b|c|  followed by  |---|---|---|
        if trim.hasPrefix("|"), trim.hasSuffix("|"), trim.count > 2,
           i + 1 < lines.count, looksLikeTableSeparator(lines[i + 1]) {
            let headers = splitTableRow(trim)
            i += 2  // consume header + separator
            var rows: [[String]] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("|"), t.hasSuffix("|"), t.count > 2 {
                    rows.append(splitTableRow(t))
                    i += 1
                } else { break }
            }
            blocks.append(.table(headers, rows))
            continue
        }

        // paragraph: collect until blank line or new block-starter
        var para: [String] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("### ")
                || t == "---" || t == "***" || t == "___"
                || t.hasPrefix("```") || t.hasPrefix("- ") || t.hasPrefix("* ")
                || t.hasPrefix("> ") || lines[i].hasPrefix("<USER>")
                || t.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                break
            }
            // table head?
            if t.hasPrefix("|"), t.hasSuffix("|"), t.count > 2,
               i + 1 < lines.count, looksLikeTableSeparator(lines[i + 1]) {
                break
            }
            para.append(lines[i])
            i += 1
        }
        if !para.isEmpty {
            blocks.append(.paragraph(para.joined(separator: "\n")))
        }
    }
    return blocks
}

// Wrapping NSTextView gives us the one feature SwiftUI Text can't: continuous
// drag-select across the whole document plus native Cmd+A / Cmd+C.
struct MarkdownView: NSViewRepresentable {
    let markdown: String
    // Bumps each time the user submits — used to trigger a one-shot scroll
    // that puts the newly-appended user question at the top of the panel.
    let scrollPin: Int

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator {
        var lastSeenPin: Int = .min
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.allowsUndo = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 14, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineBreakMode = .byWordWrapping
        tv.font = NSFont.systemFont(ofSize: 16)

        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView,
              let storage = tv.textStorage else { return }
        let attr = Self.buildAttributedString(from: markdown)
        // Batch into a single layout pass so streaming tokens don't make the
        // view flicker / jump. Scrolling is left entirely to the user.
        storage.beginEditing()
        storage.setAttributedString(attr)
        storage.endEditing()

        // One-shot scroll after a new submit: jump so the new "🧑 …" line is
        // pinned at the top of the visible area, then stay put while tokens
        // stream in below.
        if scrollPin != context.coordinator.lastSeenPin {
            context.coordinator.lastSeenPin = scrollPin
            Self.scrollLastUserToTop(tv: tv)
        }
    }

    private static func scrollLastUserToTop(tv: NSTextView) {
        guard let storage = tv.textStorage,
              let layoutManager = tv.layoutManager,
              let container = tv.textContainer else { return }
        let nsText = storage.string as NSString
        let needle = "🧑 "
        let range = nsText.range(of: needle, options: .backwards)
        guard range.location != NSNotFound else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        // textContainerInset adds top padding above the text; account for it
        // so the line ends up flush with the visible top.
        let y = lineRect.origin.y + tv.textContainerInset.height
        // Defer to the next runloop tick — by then SwiftUI's layout pass has
        // finished and the scroll view knows its real bounds.
        DispatchQueue.main.async {
            guard let scrollView = tv.enclosingScrollView else { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: Attributed-string rendering

    private static func buildAttributedString(from md: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = parseMarkdownBlocks(md)
        let textColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        let baseFont  = NSFont.systemFont(ofSize: 16)

        for (i, block) in blocks.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }

            switch block {
            case .userMsg(let text):
                let bubble = NSColor(red: 0.91, green: 0.27, blue: 0.38, alpha: 1)
                let prefix: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 17),
                    .foregroundColor: bubble
                ]
                let body: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 17, weight: .bold),
                    .foregroundColor: bubble
                ]
                result.append(NSAttributedString(string: "🧑 ", attributes: prefix))
                result.append(NSAttributedString(string: text + "\n", attributes: body))

            case .heading(let level, let text):
                let size: CGFloat = level == 1 ? 20 : level == 2 ? 18 : 17
                let font = NSFont.systemFont(ofSize: size, weight: .semibold)
                result.append(parsedInline(text, font: font, color: textColor))
                result.append(NSAttributedString(string: "\n"))

            case .paragraph(let text):
                result.append(parsedInline(text, font: baseFont, color: textColor))
                result.append(NSAttributedString(string: "\n"))

            case .codeBlock(let code):
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1),
                    .backgroundColor: NSColor(calibratedWhite: 0.95, alpha: 1)
                ]
                result.append(NSAttributedString(string: code + "\n", attributes: attrs))

            case .hr:
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: baseFont,
                    .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
                ]
                result.append(NSAttributedString(string: String(repeating: "─", count: 30) + "\n",
                                                 attributes: attrs))

            case .list(let items, let ordered):
                for (idx, item) in items.enumerated() {
                    let prefix = ordered ? "\(idx + 1). " : "• "
                    let prefixAttrs: [NSAttributedString.Key: Any] = [
                        .font: baseFont,
                        .foregroundColor: textColor
                    ]
                    result.append(NSAttributedString(string: prefix, attributes: prefixAttrs))
                    result.append(parsedInline(item, font: baseFont, color: textColor))
                    result.append(NSAttributedString(string: "\n"))
                }

            case .blockquote(let text):
                let quoteColor = NSColor(calibratedWhite: 0.35, alpha: 1)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: baseFont,
                    .foregroundColor: quoteColor
                ]
                result.append(NSAttributedString(string: "│ ", attributes: attrs))
                result.append(parsedInline(text, font: baseFont, color: quoteColor))
                result.append(NSAttributedString(string: "\n"))

            case .table(let headers, let rows):
                result.append(renderTable(headers: headers, rows: rows, textColor: textColor))
            }
        }
        return result
    }

    // Render markdown tables as monospaced columns with │ separators so they
    // line up regardless of cell length. Chinese chars are treated as 2-wide.
    private static func renderTable(headers: [String], rows: [[String]],
                                    textColor: NSColor) -> NSAttributedString {
        let allRows = [headers] + rows
        let cols = headers.count
        guard cols > 0 else { return NSAttributedString(string: "") }

        func displayWidth(_ s: String) -> Int {
            s.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
        }

        var widths = Array(repeating: 0, count: cols)
        for row in allRows {
            for (i, cell) in row.enumerated() where i < cols {
                let w = displayWidth(cell)
                if w > widths[i] { widths[i] = w }
            }
        }

        func pad(_ s: String, to width: Int) -> String {
            let n = max(0, width - displayWidth(s))
            return s + String(repeating: " ", count: n)
        }

        func renderRow(_ cells: [String]) -> String {
            var parts: [String] = []
            for i in 0..<cols {
                let cell = i < cells.count ? cells[i] : ""
                parts.append(pad(cell, to: widths[i]))
            }
            return parts.joined(separator: " │ ")
        }

        let mono = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: textColor
        ]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: monoBold,
            .foregroundColor: textColor
        ]

        let result = NSMutableAttributedString()
        // Header
        result.append(NSAttributedString(string: renderRow(headers) + "\n", attributes: headerAttrs))
        // Separator
        let sepParts = widths.map { String(repeating: "─", count: $0) }
        result.append(NSAttributedString(string: sepParts.joined(separator: "─┼─") + "\n",
                                         attributes: baseAttrs))
        // Rows
        for row in rows {
            result.append(NSAttributedString(string: renderRow(row) + "\n", attributes: baseAttrs))
        }
        return result
    }

    // Render inline markdown (bold/italic/code) preserving the supplied default
    // font/color while letting markdown traits override per-range font.
    private static func parsedInline(_ s: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: s, options: opts) else {
            return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let full = NSRange(location: 0, length: ns.length)

        // Force the requested foreground color over the whole string.
        ns.addAttribute(.foregroundColor, value: color, range: full)

        // Wherever Foundation set a font (for bold / italic / code spans), rescale it
        // to the requested base size while preserving the trait. Wherever it didn't
        // set one, fill in the base font.
        ns.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if let existing = value as? NSFont {
                let traits = existing.fontDescriptor.symbolicTraits
                let scaled = font.fontDescriptor.withSymbolicTraits(traits)
                if let newFont = NSFont(descriptor: scaled, size: font.pointSize) {
                    ns.addAttribute(.font, value: newFont, range: range)
                }
            } else {
                ns.addAttribute(.font, value: font, range: range)
            }
        }
        return ns
    }
}

// MARK: - SwiftUI Views
struct BarView: View {
    @ObservedObject var viewModel: BarViewModel
    @ObservedObject var eyeCare: EyeCareManager
    @FocusState private var inputFocused: Bool

    private let bg = Color.white
    // Uniform tap-target size for icon buttons in the expanded row, so SF
    // Symbols of differing intrinsic shapes (chevron vs trash etc.) all sit at
    // the same vertical position.
    private let iconBox: CGSize = CGSize(width: 16, height: 16)
    // Pushes each button down so its icon centers with the input box's first
    // text line (input has 3pt top padding; line center ~11pt; icon center is
    // at 8pt within its 16pt frame; difference ≈ 3pt).
    private let btnTopPad: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            // Single-line bar (input auto-grows when content wraps).
            // Alignment must stay .top so the hidden text mirror inside the
            // input box can grow downward and the panel auto-expands; buttons
            // get a consistent .padding(.top, …) below to line up with the
            // input's first text line.
            HStack(alignment: .top, spacing: 6) {
                // ── INPUT (left) ────────────────────────────────────────────
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.input)
                        .font(.system(size: 16))
                        .foregroundColor(.black)
                        .scrollContentBackground(.hidden)
                        .focused($inputFocused)

                    if viewModel.input.isEmpty {
                        Text("ask anything... (use / to start new session)")
                            .font(.system(size: 16))
                            .foregroundColor(Color(white: 0.55))
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 100)  // ~4 lines at 16pt
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.white)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.7), lineWidth: 1))

                // ── BUTTONS (right, two rows) ───────────────────────────────
                VStack(alignment: .trailing, spacing: 8) {
                    // Top row: utility icons
                    HStack(spacing: 6) {
                        if viewModel.isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: iconBox.width, height: iconBox.height)
                        }

                        Button(action: {
                            viewModel.input = ""
                            viewModel.pastedImages = []
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.5))
                                .frame(width: iconBox.width, height: iconBox.height)
                        }
                        .buttonStyle(.plain)
                        .help("清空 / Clear input")

                        Button(action: {
                            if let str = NSPasteboard.general.string(forType: .string) {
                                viewModel.input = str
                            }
                        }) {
                            Image(systemName: "clipboard")
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.5))
                                .frame(width: iconBox.width, height: iconBox.height)
                        }
                        .buttonStyle(.plain)
                        .help("粘贴 / Paste")

                        Menu {
                            ForEach(viewModel.models, id: \.self) { m in
                                Button(action: { viewModel.model = m }) {
                                    if viewModel.model == m {
                                        Label(modelDisplayName(m), systemImage: "checkmark")
                                    } else {
                                        Text(modelDisplayName(m))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(modelDisplayName(viewModel.model))
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.4))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundColor(Color(white: 0.55))
                            }
                            .frame(width: 86, height: iconBox.height, alignment: .leading)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("选择模型 / Pick model")

                        if viewModel.isRefreshingModels {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: iconBox.width, height: iconBox.height)
                        } else {
                            Button(action: { viewModel.refreshModels() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color(white: 0.5))
                                    .frame(width: iconBox.width, height: iconBox.height)
                            }
                            .buttonStyle(.plain)
                            .help("刷新模型列表 / Refresh model list")
                        }
                    }

                    // Row 2: English-language tools — prefixed with "英:"
                    HStack(spacing: 6) {
                        Text("英:")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.4))
                        captionButton(icon: "checkmark.seal", title: "纠",
                                      help: "英语纠错 / Correct my English", action: doCorrect)
                        captionButton(icon: "text.magnifyingglass", title: "解读",
                                      help: "难句解读 / Explain hard sentence",
                                      action: doExplain)
                        dotSeparator
                        captionButton(icon: "book.closed", title: "词源",
                                      help: "英语词源 / Etymology", action: doEtymology)
                    }

                    // Row 3 (last): primary send action + eye-care countdown
                    HStack(spacing: 10) {
                        captionButton(icon: "paperplane.fill", title: "send",
                                      help: "发送 / Send", action: doSubmit)
                        if !eyeCare.remainingText.isEmpty {
                            Text(eyeCare.remainingText)
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(Color(white: 0.55))
                                .help("距下次护眼休息 / time to next eye break")
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(white: 0.95).opacity(0.9))

            // Image thumbnails row (when there are pasted images)
            if !viewModel.pastedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.pastedImages) { img in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: img.nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 60, maxHeight: 40)
                                    .cornerRadius(4)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.7), lineWidth: 0.5))
                                Button(action: {
                                    viewModel.pastedImages.removeAll { $0.id == img.id }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.black.opacity(0.6))
                                        .background(Circle().fill(Color.white))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 50)
                .background(Color(white: 0.97))
            }

            // Result dropdown
            if viewModel.showOutput {
                Rectangle().fill(Color(white: 0.85)).frame(height: 0.5)
                MarkdownView(markdown: viewModel.output + (viewModel.isLoading ? "\n\n▊" : ""),
                             scrollPin: viewModel.scrollPinTick)
                    .frame(maxHeight: 280)
                    .background(bg)
                    .overlay(alignment: .topTrailing) {
                        if viewModel.isLoading {
                            // Spinner = "still alive", "stop" label = clickable
                            // to cancel the in-flight stream right now.
                            Button(action: doStop) {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.55)
                                        .frame(width: 12, height: 12)
                                    Text("stop")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.85))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                            .help("停止生成 / Stop")
                        } else if !viewModel.output.isEmpty {
                            HStack(spacing: 6) {
                                // Copy: full output text → clipboard.
                                Button(action: copyOutput) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 9, weight: .medium))
                                        Text("copy")
                                            .font(.system(size: 10))
                                    }
                                    .foregroundColor(Color(white: 0.4))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.85))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .help("复制结果 / Copy output")

                                // Retry: re-ask the most recent question.
                                if viewModel.lastUserText != nil {
                                    Button(action: doRetry) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 9, weight: .medium))
                                            Text("retry")
                                                .font(.system(size: 10))
                                        }
                                        .foregroundColor(Color(white: 0.4))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.white.opacity(0.85))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .help("重新提问 / Retry")
                                }
                            }
                            .padding(8)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.8), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
        .onChange(of: viewModel.focusInput) { newVal in
            if newVal { inputFocused = true; viewModel.focusInput = false }
        }
        .onExitCommand {
            // Esc → hide the whole bar (consistent with click-outside / blur).
            (NSApp.delegate as? AppDelegate)?.panel.orderOut(nil)
        }
    }

    private func doSubmit() {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        viewModel.submit { h in d.resizePanel(height: h) }
    }

    private func doRetry() {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        viewModel.retry { h in d.resizePanel(height: h) }
    }

    private func doStop() {
        viewModel.stop()
    }

    private func doCorrect() {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        viewModel.submit(mode: .corrector) { h in d.resizePanel(height: h) }
    }

    private func doEtymology() {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        viewModel.submit(mode: .etymology) { h in d.resizePanel(height: h) }
    }

    private func doExplain() {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        viewModel.submit(mode: .explain) { h in d.resizePanel(height: h) }
    }

    // Small middle-dot used as a visual separator between caption buttons.
    private var dotSeparator: some View {
        Text("·")
            .font(.system(size: 12))
            .foregroundColor(Color(white: 0.55))
    }

    // Compact icon + text label button, used for the second row of action
    // buttons (send / correct / etym).
    @ViewBuilder
    private func captionButton(icon: String, title: String,
                               help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundColor(Color(white: 0.4))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // Shorten "claude-sonnet-4-5" → "sonnet-4-5" for the compact menu label.
    private func modelDisplayName(_ m: String) -> String {
        if m.hasPrefix("claude-") { return String(m.dropFirst("claude-".count)) }
        return m
    }
    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.output, forType: .string)
    }

}

// MARK: - Eye-care (20-20-20)
//
// Cycle: work `workMinutes` (default 20) → 1-minute "break" → repeat.
// During the break the menu-bar icon turns into a menacing red eye (always),
// and — UNLESS the mic is in use (i.e. you're in a meeting / sharing screen) —
// a soft full-screen overlay is shown to make you look ~6 m away for 20s.
//
// Pausing: while the screen is locked / asleep / screensaver-ed, the timer is
// dormant (you're not looking at the screen → eyes already resting). On return
// we measure how long you were away: < resetGap (60s) → treat as a non-event
// and resume; ≥ resetGap → eyes rested, reset the work clock to zero.
final class EyeCareManager: ObservableObject {
    private weak var app: AppDelegate?

    // Live readout for the bar: time until the next break ("18:32"), "👀 0:45"
    // during a break, or "" when disabled / paused. Updated every second.
    @Published var remainingText: String = ""
    private var started = false

    private let workSeconds: TimeInterval
    private let breakSeconds: TimeInterval
    private let autoCloseSeconds: TimeInterval
    private let resetGapSeconds: TimeInterval
    private let popupIdleSkipSeconds: TimeInterval

    private enum Phase { case working, breaking, paused }
    private var phase: Phase = .working
    private var phaseBeforePause: Phase = .working

    private var workStart = Date()
    private var breakStart = Date()
    private var pausedAt: Date?
    private var overlayShown = false

    private var heartbeat: Timer?
    private var overlays: [NSPanel] = []
    private var escMonitor: Any?

    init(app: AppDelegate) {
        self.app = app
        let c = EngConfig.shared
        workSeconds      = (c.eyeWorkMinutes ?? 20) * 60
        breakSeconds     = c.eyeBreakSeconds ?? 60
        autoCloseSeconds = c.eyeAutoCloseSeconds ?? 30
        resetGapSeconds  = c.eyeResetGapSeconds ?? 60
        popupIdleSkipSeconds = c.eyePopupIdleSkipSeconds ?? 600
    }

    // Whether to actually show the popup at break time. Suppressed when the
    // mic is in use (meeting / screen share) OR the machine has been idle for
    // a while (you're working on another computer) — icon still goes red.
    private var shouldShowPopup: Bool {
        !Self.isMicInUse() && Self.secondsSinceInput() < popupIdleSkipSeconds
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(pause), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(resume), name: NSWorkspace.didWakeNotification, object: nil)
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(self, selector: #selector(pause), name: .init("com.apple.screenIsLocked"), object: nil)
        dc.addObserver(self, selector: #selector(resume), name: .init("com.apple.screenIsUnlocked"), object: nil)
        dc.addObserver(self, selector: #selector(pause), name: .init("com.apple.screensaver.didstart"), object: nil)
        dc.addObserver(self, selector: #selector(resume), name: .init("com.apple.screensaver.didstop"), object: nil)

        started = true
        workStart = Date()
        phase = .working
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
        updateRemaining()
    }

    // MARK: heartbeat

    private func mmss(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func updateRemaining() {
        guard started else { remainingText = ""; return }
        switch phase {
        case .working:
            remainingText = mmss(workSeconds - Date().timeIntervalSince(workStart))
        case .breaking:
            remainingText = "👀 " + mmss(breakSeconds - Date().timeIntervalSince(breakStart))
        case .paused:
            remainingText = ""
        }
    }

    @objc private func tick() {
        updateRemaining()
        switch phase {
        case .paused:
            return
        case .working:
            if Date().timeIntervalSince(workStart) >= workSeconds {
                beginBreak()
            }
        case .breaking:
            let elapsed = Date().timeIntervalSince(breakStart)
            if elapsed >= breakSeconds {
                endBreak()
            } else if overlayShown && Self.secondsSinceInput() >= autoCloseSeconds {
                // Nobody's here → that's also rest. Close the popup (icon stays
                // red until the minute is up), but don't end the break early.
                closeOverlay()
            }
        }
    }

    private func beginBreak() {
        phase = .breaking
        breakStart = Date()
        // Static closed-eye icon on the neon block — noticeable but discreet
        // (no staring open eye / blinking, so it's not embarrassing on a shared
        // screen). ALWAYS shown, even in a meeting / when idle.
        app?.setEyeAlertIcon(true, closed: true)
        if shouldShowPopup {                  // meeting or long-idle → icon only, no popup
            showOverlay()
        }
    }

    private func endBreak() {
        closeOverlay()
        app?.setEyeAlertIcon(false)
        workStart = Date()
        phase = .working
    }

    // MARK: pause / resume (lock, sleep, screensaver)

    @objc private func pause() {
        guard pausedAt == nil else { return }   // idempotent (lid-close fires several)
        pausedAt = Date()
        phaseBeforePause = (phase == .paused) ? .working : phase
        // Tear down any visible break — you're leaving the screen anyway.
        closeOverlay()
        app?.setEyeAlertIcon(false)
        phase = .paused
    }

    @objc private func resume() {
        guard let since = pausedAt else { return }
        pausedAt = nil
        let gap = Date().timeIntervalSince(since)
        if gap >= resetGapSeconds {
            // Long enough away that the eyes rested → restart the work clock.
            workStart = Date()
            phase = .working
        } else {
            // Brief lock (a test, a glance) → pretend it never happened: shift
            // the timestamps forward by the gap and carry on where we left off.
            workStart = workStart.addingTimeInterval(gap)
            breakStart = breakStart.addingTimeInterval(gap)
            phase = phaseBeforePause
            if phase == .breaking {
                app?.setEyeAlertIcon(true, closed: true)
                if shouldShowPopup && overlays.isEmpty { showOverlay() }
            }
        }
    }

    // MARK: overlay

    private func showOverlay() {
        guard overlays.isEmpty else { return }
        // Only the built-in MacBook display (fall back to the main screen, then
        // any screen). On multi-monitor setups we don't blanket every external.
        let screen = Self.builtinScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let p = NSPanel(contentRect: screen.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Skip only dismisses the popup; the red-eye icon stays for the full
        // break minute (passive nag), then the heartbeat ends the break.
        p.contentView = NSHostingView(rootView: EyeBreakView(onSkip: { [weak self] in self?.closeOverlay() }))
        p.setFrame(screen.frame, display: true)
        p.orderFrontRegardless()
        overlays.append(p)
        overlayShown = true

        // Esc closes the overlay (skip) without stealing keyboard focus globally.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.closeOverlay(); return nil }   // Esc → dismiss popup, icon stays red
            return e
        }
    }

    private func closeOverlay() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        overlayShown = false
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    /// The built-in laptop display, if one is currently active.
    static func builtinScreen() -> NSScreen? {
        NSScreen.screens.first { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(n) != 0
        }
    }

    // MARK: signals

    /// True when any process is actively using the default input device — the
    /// same thing that lights the orange mic dot. Covers Zoom/Teams (even when
    /// muted-in-app) and browser-based meetings.
    static func isMicInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return false }
        var running = UInt32(0)
        var rsize = UInt32(MemoryLayout<UInt32>.size)
        var raddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &raddr, 0, nil, &rsize, &running) == noErr
        else { return false }
        return running != 0
    }

    /// Seconds since the last keyboard/mouse input, system-wide.
    static func secondsSinceInput() -> TimeInterval {
        let any = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}

// MARK: - Eye-care break overlay

struct EyeBreakView: View {
    var onSkip: () -> Void
    @State private var remaining = 20

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 22) {
                Text("👀")
                    .font(.system(size: 70))
                Text("Look 20 feet away")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white)
                Text("Rest your eyes — 20-20-20")
                    .font(.system(size: 16))
                    .foregroundColor(Color(white: 0.75))

                Text("\(max(remaining, 0))")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .padding(.top, 4)

                Button(action: onSkip) {
                    Text("Skip  (Esc)")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.85))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .onReceive(tick) { _ in
            if remaining > 0 { remaining -= 1 }
        }
    }
}
