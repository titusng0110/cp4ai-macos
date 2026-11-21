import AppKit
import CP4AICore
import Foundation

final class ProgressController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let statusLabel: NSTextField
    private let bar: NSProgressIndicator
    private let detailLabel: NSTextField
    private let closeButton: NSButton

    override init() {
        let style: NSWindow.StyleMask = [.titled, .closable]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        statusLabel = NSTextField(labelWithString: "Ready")
        bar = NSProgressIndicator()
        detailLabel = NSTextField(labelWithString: "")
        closeButton = NSButton(title: "Close", target: nil, action: nil)

        super.init()

        window.title = "Copy 4 AI"
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        guard let content = window.contentView else { return }

        statusLabel.frame = NSRect(x: 20, y: 62, width: 320, height: 18)
        statusLabel.font = NSFont.boldSystemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1
        content.addSubview(statusLabel)

        bar.frame = NSRect(x: 20, y: 38, width: 320, height: 12)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0
        content.addSubview(bar)

        detailLabel.frame = NSRect(x: 20, y: 14, width: 260, height: 16)
        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        content.addSubview(detailLabel)

        closeButton.frame = NSRect(x: 296, y: 6, width: 52, height: 26)
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.isHidden = true
        content.addSubview(closeButton)
    }

    func begin(count: Int, skipped: Int) {
        statusLabel.stringValue = skipped > 0
            ? "Processing \(count) file(s), \(skipped) skipped…"
            : "Processing \(count) file(s)…"
        detailLabel.stringValue = ""
        detailLabel.toolTip = nil
        setIndeterminate(true)
        bar.doubleValue = 0
        closeButton.isHidden = true
        show()
    }

    func queued() {
        statusLabel.stringValue = "Another batch queued…"
        show()
    }

    func updateWork(_ state: WorkState) {
        setIndeterminate(false)
        bar.doubleValue = state.fraction * 100
        if state.documentsTotal > 0 {
            var text = "\(state.documentsDone)/\(state.documentsTotal) documents"
            if state.imagesTotal > 0 || state.imagesDone > 0 {
                text += " + \(state.imagesDone)/\(state.imagesTotal) images"
            }
            statusLabel.stringValue = text
        } else {
            statusLabel.stringValue = "Starting…"
        }
    }

    func updateFile(index: Int, total: Int, name: String, error: String?) {
        let suffix = error == nil ? "" : " (failed)"
        detailLabel.stringValue = "(\(index)/\(total)) \(name)\(suffix)"
        detailLabel.toolTip = error
    }

    func success(characters: Int, tokens: Int) {
        setIndeterminate(false)
        bar.doubleValue = 100
        statusLabel.stringValue = "Copied to clipboard!"
        detailLabel.stringValue = "\(characters.formatted()) characters · \(tokens.formatted()) tokens"
        detailLabel.toolTip = nil
        closeButton.isHidden = false
        show()
    }

    func failure(_ message: String) {
        setIndeterminate(false)
        bar.doubleValue = 0
        statusLabel.stringValue = "Couldn't copy"
        let singleLine = message.replacingOccurrences(of: "\n", with: " ")
        detailLabel.stringValue = String(singleLine.prefix(240))
        detailLabel.toolTip = message
        closeButton.isHidden = false
        show()
    }

    func hide() {
        window.orderOut(nil)
    }

    private func setIndeterminate(_ value: Bool) {
        bar.isIndeterminate = value
        if value {
            bar.startAnimation(nil)
        } else {
            bar.stopAnimation(nil)
        }
    }

    private func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func close() {
        window.close()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
