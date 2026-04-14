import Foundation
import AppKit
import CoreGraphics

/// Manages a virtual display for agent input isolation.
/// Uses the private CGVirtualDisplay API (same approach as scripts/create-virtual-display.m).
/// Each sandbox gets its own virtual monitor — agents control it via CGEvent targeting,
/// while the user's physical display remains untouched.
@MainActor
final class AgentSandbox: ObservableObject, Identifiable {
    let id: UUID
    let name: String

    /// The CGDirectDisplayID of the virtual display (nil if not yet created).
    @Published private(set) var displayID: CGDirectDisplayID?

    /// Resolution of the virtual display.
    let resolution: CGSize

    /// Whether the sandbox is currently active.
    @Published private(set) var isActive: Bool = false

    /// Error message if creation failed.
    @Published private(set) var errorMessage: String?

    /// The underlying CGVirtualDisplay object (retained to keep display alive).
    private var virtualDisplay: AnyObject?

    /// The display descriptor (retained).
    private var displayDescriptor: AnyObject?

    // MARK: - Init

    init(name: String, resolution: CGSize = CGSize(width: 1920, height: 1080)) {
        self.id = UUID()
        self.name = name
        self.resolution = resolution
    }

    deinit {
        // Display is destroyed when the CGVirtualDisplay object is deallocated
        virtualDisplay = nil
        displayDescriptor = nil
    }

    // MARK: - Lifecycle

    /// Create the virtual display. Returns the display ID on success.
    @discardableResult
    func createDisplay() -> CGDirectDisplayID? {
        guard !isActive else { return displayID }

        // Verify the private API is available
        guard let displayClass = NSClassFromString("CGVirtualDisplay"),
              let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
            errorMessage = "CGVirtualDisplay API not available on this system"
            return nil
        }

        // Create display mode
        let width = UInt32(resolution.width)
        let height = UInt32(resolution.height)

        guard let mode = createDisplayMode(modeClass: modeClass, width: width, height: height) else {
            errorMessage = "Failed to create CGVirtualDisplayMode"
            return nil
        }

        // Create descriptor
        let descriptor = descriptorClass.init()
        descriptor.setValue("cmux Agent Sandbox: \(name)", forKey: "name")
        descriptor.setValue(width, forKey: "maxPixelsWide")
        descriptor.setValue(height, forKey: "maxPixelsHigh")
        descriptor.setValue(CGSize(width: 530, height: 300), forKey: "sizeInMillimeters")
        descriptor.setValue(UInt32(0x1234), forKey: "vendorID")
        descriptor.setValue(UInt32(0x5678), forKey: "productID")
        descriptor.setValue(UInt32(id.hashValue & 0xFFFF), forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        self.displayDescriptor = descriptor

        // Create virtual display
        let initSelector = NSSelectorFromString("initWithDescriptor:")
        guard displayClass.instancesRespond(to: initSelector) else {
            errorMessage = "CGVirtualDisplay missing initWithDescriptor:"
            return nil
        }

        let display = (displayClass as! NSObject.Type).init()
        let result = display.perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)
        guard let createdDisplay = result?.takeUnretainedValue() as? NSObject else {
            errorMessage = "Failed to create CGVirtualDisplay"
            return nil
        }

        // Apply settings with the display mode
        let settings = settingsClass.init()
        settings.setValue(UInt32(0), forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")

        let applySelector = NSSelectorFromString("applySettings:")
        guard createdDisplay.responds(to: applySelector) else {
            errorMessage = "CGVirtualDisplay missing applySettings:"
            return nil
        }

        let applied = createdDisplay.perform(applySelector, with: settings)
        // applySettings: returns BOOL — check via pointer
        let success = applied != nil

        guard success else {
            errorMessage = "Failed to apply display settings"
            return nil
        }

        // Get the display ID
        guard let idValue = createdDisplay.value(forKey: "displayID") as? UInt32 else {
            errorMessage = "Failed to get displayID from virtual display"
            return nil
        }

        self.virtualDisplay = createdDisplay
        self.displayID = idValue
        self.isActive = true
        self.errorMessage = nil

        return idValue
    }

    /// Destroy the virtual display.
    func destroyDisplay() {
        virtualDisplay = nil
        displayDescriptor = nil
        displayID = nil
        isActive = false
    }

    // MARK: - Screenshot

    /// Capture a screenshot of the virtual display as PNG data.
    func captureScreenshot() -> Data? {
        guard let displayID else { return nil }

        guard let image = CGDisplayCreateImage(displayID) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // MARK: - Input Injection

    /// Inject a mouse click event into the virtual display's coordinate space.
    func injectClick(at point: CGPoint, button: CGMouseButton = .left) {
        guard let displayID else { return }

        // Create mouse events targeted at the virtual display
        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: button == .left ? .leftMouseDown : .rightMouseDown,
            mouseCursorPosition: point,
            mouseButton: button
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: button == .left ? .leftMouseUp : .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: button
        )

        // Target the virtual display
        mouseDown?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(displayID))
        mouseUp?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(displayID))

        mouseDown?.post(tap: .cgSessionEventTap)
        mouseUp?.post(tap: .cgSessionEventTap)
    }

    /// Inject a key event into the virtual display.
    func injectKey(_ keyCode: CGKeyCode, keyDown: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
        event?.post(tap: .cgSessionEventTap)
    }

    /// Inject typed text via keyboard events.
    func injectText(_ text: String) {
        for char in text {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            var chars = [UniChar](String(char).utf16)
            event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            event?.post(tap: .cgSessionEventTap)

            let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            upEvent?.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Private

    private func createDisplayMode(modeClass: NSObject.Type, width: UInt32, height: UInt32) -> AnyObject? {
        let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard modeClass.instancesRespond(to: selector) else { return nil }

        let mode = modeClass.init()
        let result = mode.perform(selector, with: width, with: height)
        return result?.takeUnretainedValue()
    }
}
