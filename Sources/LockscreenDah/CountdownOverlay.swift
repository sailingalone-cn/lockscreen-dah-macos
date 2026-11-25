import AppKit
import AVFoundation

/// The overlay that blacks out every screen: either a countdown before a lock,
/// or the message-free dim surface.
///
/// Windows are built once and then reused. Rebuilding them on every show/dismiss
/// meant creating and destroying full-screen windows at `.screenSaver` level
/// several times a minute; that churn is the leading suspect behind the
/// WindowServer watchdog panics (its main thread was stuck in a recursive
/// QuartzCore call), so presentation is now `orderFrontRegardless`/`orderOut` on
/// existing windows, with no CoreAnimation fade.
final class CountdownOverlay: NSObject {
    var onEscape: (() -> Void)?

    private var windows: [EscapableWindow] = []
    private var countdownLabels: [NSTextField] = []
    private var hintLabels: [NSTextField] = []
    private var hint: String?
    /// Last value passed to `show`/`update`, so a rebuild can redraw immediately.
    private var lastRemaining: TimeInterval = 0
    private var screenObserver: NSObjectProtocol?
    /// True while this is the message-free dim surface rather than a countdown.
    private var isBlank = false
    /// Whether the overlay is currently on screen.
    private var isPresented = false
    /// `NSApp.activate` is only worth one call; repeating it on every presentation
    /// is more window-server traffic for no benefit.
    private var hasActivated = false

    func show(remaining: TimeInterval) {
        // A fresh countdown must not inherit a hint from the previous one.
        hint = nil
        present(showCountdown: true)
        update(remaining: remaining)
        applyHint()
        if let chime = NSSound(named: "Tink") {
            chime.volume = 0.5
            chime.play()
        }
    }

    /// The dim-mode surface: a blank takeover of every screen, no countdown, no
    /// hint, no chime. Kept message-free on purpose — to a passerby it must read
    /// as a display that went to sleep, and the owner is not there to read
    /// anything.
    func showBlank() {
        present(showCountdown: false)
        lastRemaining = 0
    }

    func dismiss() {
        isPresented = false
        for window in windows {
            window.orderOut(nil)
        }
    }

    func update(remaining: TimeInterval) {
        lastRemaining = remaining
        let seconds = max(0, Int(remaining.rounded(.up)))
        let text = "\(seconds)"
        for label in countdownLabels where label.stringValue != text {
            label.stringValue = text
        }
    }

    /// Revealed only once the user has actually pressed Esc, so the gesture
    /// isn't advertised to someone walking past a blacked-out screen.
    func setHint(_ text: String?) {
        hint = text
        applyHint()
    }

    // MARK: - Presentation

    private func present(showCountdown: Bool) {
        isBlank = !showCountdown
        isPresented = true
        ensureWindows()

        for label in countdownLabels { label.isHidden = !showCountdown }
        for label in hintLabels { label.isHidden = !showCountdown }

        for window in windows {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
        // Key focus so stray keystrokes land on the (inert) overlay instead of
        // whatever window was exposed underneath. Esc is handled there.
        if let first = windows.first, !first.isKeyWindow {
            first.makeKey()
        }
        if !hasActivated {
            hasActivated = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func ensureWindows() {
        guard windows.isEmpty else { return }
        installScreenObserver()
        rebuildWindows()
    }

    /// A display attached (or rearranged) mid-overlay would otherwise stay
    /// uncovered. This is the only case that still rebuilds — it is rare, and a
    /// stale window covering the wrong screen is worse than one rebuild.
    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.windows.isEmpty else { return }
            self.rebuildWindows()
            if self.isPresented { self.present(showCountdown: !self.isBlank) }
        }
    }

    private func rebuildWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        countdownLabels.removeAll()
        hintLabels.removeAll()

        for screen in NSScreen.screens {
            let window = EscapableWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.onEscape = { [weak self] in self?.onEscape?() }
            window.alphaValue = 1

            let countdown = NSTextField(labelWithString: "")
            countdown.font = .monospacedDigitSystemFont(ofSize: 42, weight: .medium)
            countdown.textColor = NSColor.white.withAlphaComponent(0.28)
            countdown.alignment = .right
            countdown.translatesAutoresizingMaskIntoConstraints = false
            countdownLabels.append(countdown)

            let hintLabel = NSTextField(labelWithString: "")
            hintLabel.font = .systemFont(ofSize: 13, weight: .regular)
            hintLabel.textColor = NSColor.white.withAlphaComponent(0.28)
            hintLabel.alignment = .right
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            hintLabels.append(hintLabel)

            let content = NSView(frame: screen.frame)
            content.addSubview(countdown)
            content.addSubview(hintLabel)
            NSLayoutConstraint.activate([
                countdown.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -44),
                countdown.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
                hintLabel.trailingAnchor.constraint(equalTo: countdown.trailingAnchor),
                hintLabel.bottomAnchor.constraint(equalTo: countdown.topAnchor, constant: -6),
            ])
            window.contentView = content
            windows.append(window)
        }
    }

    private func applyHint() {
        let text = hint ?? ""
        for label in hintLabels where label.stringValue != text {
            label.stringValue = text
        }
    }
}

/// Borderless windows can't become key by default; this one can, and turns
/// Esc into a cancel callback while swallowing every other event.
private final class EscapableWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscape?()
        }
        // Swallow everything else — keystrokes must not reach hidden windows.
    }
}
