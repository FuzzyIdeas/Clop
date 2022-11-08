import Cocoa
import Combine
import Foundation
import SwiftUI

@discardableResult
public func mainAsyncAfter(ms: Int, _ action: @escaping () -> Void) -> DispatchWorkItem {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    let workItem = DispatchWorkItem {
        action()
    }
    DispatchQueue.main.asyncAfter(deadline: deadline, execute: workItem)

    return workItem
}

// MARK: - OSDWindow

open class OSDWindow: NSWindow, NSWindowDelegate {
    // MARK: Lifecycle

    public convenience init(
        swiftuiView: AnyView,
        allSpaces: Bool = true,
        canScreenshot: Bool = true,
        screen: NSScreen? = nil,
        corner: ScreenCorner? = nil,
        allowsMouse: Bool = false
    ) {
        self.init(contentViewController: NSHostingController(rootView: swiftuiView))

        screenPlacement = screen
        screenCorner = corner

        level = .floating
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenDisallowsTiling]
        if allSpaces {
            collectionBehavior.formUnion(.canJoinAllSpaces)
        } else {
            collectionBehavior.formUnion(.moveToActiveSpace)
        }
        if !canScreenshot {
            sharingType = .none
        }
        ignoresMouseEvents = !allowsMouse
        setAccessibilityRole(.popover)
        setAccessibilitySubrole(.unknown)

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        styleMask = [.fullSizeContentView]
        hidesOnDeactivate = false
        delegate = self
    }

    // MARK: Open

    open var onClick: ((NSEvent) -> Void)?

    override open func mouseDown(with event: NSEvent) {
        guard !ignoresMouseEvents, let onClick else { return }
        onClick(event)
    }

    open func show(
        at point: NSPoint? = nil,
        closeAfter closeMilliseconds: Int = 3050,
        fadeAfter fadeMilliseconds: Int = 2000,
        fadeDuration: TimeInterval = 1,
        offCenter: CGFloat? = nil,
        centerWindow: Bool = true,
        corner: ScreenCorner? = nil,
        screen: NSScreen? = nil
    ) {
        if let corner {
            moveToScreen(screen, corner: corner)
        } else if let point {
            setFrameOrigin(point)
        } else if let screenFrame = (screen ?? NSScreen.main)?.visibleFrame {
            setFrameOrigin(screenFrame.origin)
            if centerWindow { center() }
            if offCenter != 0 {
                let yOff = screenFrame.height / (offCenter ?? 2.2)
                setFrame(frame.offsetBy(dx: 0, dy: -yOff), display: false)
            }
        }

        alphaValue = 1
        wc.showWindow(nil)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        closer?.cancel()
        guard closeMilliseconds > 0 else { return }
        fader = mainAsyncAfter(ms: fadeMilliseconds) { [weak self] in
            guard let self, self.isVisible else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeDuration
                self.animator().alphaValue = 0.01
            }

            self.closer = mainAsyncAfter(ms: closeMilliseconds) { [weak self] in
                self?.close()
            }
        }
    }

    // MARK: Public

    @Published public var screenPlacement: NSScreen?

    public func windowDidResize(_ notification: Notification) {
        guard let screenCorner, let screenPlacement else { return }
        moveToScreen(screenPlacement, corner: screenCorner)
    }

    public func resizeToScreenHeight(_ screen: NSScreen? = nil) {
        guard let screenFrame = (screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        setContentSize(NSSize(width: frame.width, height: screenFrame.height))
    }

    public func moveToScreen(_ screen: NSScreen? = nil, corner: ScreenCorner? = nil) {
        guard let screenFrame = (screen ?? NSScreen.main)?.visibleFrame else {
            return
        }

        if let screen {
            screenPlacement = screen
        }

        guard let corner else {
            setFrameOrigin(screenFrame.origin)
            return
        }

        screenCorner = corner
        let o = screenFrame.origin
        let f = screenFrame

        switch corner {
        case .bottomLeft:
            setFrameOrigin(screenFrame.origin)
        case .bottomRight:
            setFrameOrigin(NSPoint(x: (o.x + f.width) - frame.width, y: o.y))
        case .topLeft:
            setFrameOrigin(NSPoint(x: o.x, y: (o.y + f.height) - frame.height))
        case .topRight:
            setFrameOrigin(NSPoint(x: (o.x + f.width) - frame.width, y: (o.y + f.height) - frame.height))
        }
    }

    public func centerOnScreen(_: NSScreen? = nil) {
        if let screenFrame = NSScreen.main?.visibleFrame {
            setFrameOrigin(screenFrame.origin)
        }
        center()
    }

    // MARK: Internal

    var screenCorner: ScreenCorner?

    var closer: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    var fader: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    // MARK: Private

    private lazy var wc = NSWindowController(window: self)
}

// MARK: - ScreenCorner

public enum ScreenCorner: Int, Codable {
    case bottomLeft
    case bottomRight
    case topLeft
    case topRight
}
