import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit
import VirtualDisplay

/// "Two displays" layout: two virtual panels that macOS treats as separate
/// monitors, drawn side by side onto the dock's wide signal.
///
/// - The physical (wide) display gets a borderless overlay window covering it.
/// - Each virtual display is captured with ScreenCaptureKit (needs Screen
///   Recording permission; protected content is black by design) and shown in
///   one half of the overlay. `swapSides` only changes which half.
/// - The pointer is kept off the physical display, and existing windows are
///   moved onto the virtual panels before the overlay goes up.
/// Every step waits for macOS to report the change as done, and the layout is
/// verified before the overlay and pointer guard are switched on. If the app
/// exits, macOS removes the virtual displays on its own.
@MainActor
final class TwoDisplayController: NSObject, ObservableObject {
	@Published private(set) var running = false
	@Published private(set) var status: String?

	var swapSides = false {
		didSet { layoutLayers() }
	}

	private var panels: [CGVirtualDisplay] = []
	private var streams: [SCStream] = []
	private var outputs: [PanelOutput] = []
	private var overlay: NSWindow?
	private var layers: [CALayer] = []
	private var physical: CGDirectDisplayID = 0
	private var guardTimer: Timer?
	private var panelSize = CGSize.zero
	private var screenObserver: Any?

	static var hasCapturePermission: Bool { CGPreflightScreenCaptureAccess() }
	static func requestCapturePermission() { CGRequestScreenCaptureAccess() }

	var panelIDs: [CGDirectDisplayID] { panels.map(\.displayID) }

	/// Start on `physical`, whose mode list must contain `wide`.
	func start(physical: CGDirectDisplayID, wide: DisplayMode) async throws {
		guard !running else { return }
		guard Self.hasCapturePermission else {
			throw HubError("WD19 Split needs Screen Recording permission (System Settings → Privacy & Security).")
		}
		let w = wide.width / 2, h = wide.height
		self.physical = physical
		panelSize = CGSize(width: w, height: h)
		Log.write("two: start physical=\(physical) wide=\(wide) panel=\(w)x\(h)")
		status = "Creating displays…"

		let left = try makePanel(name: "WD19 Left", serial: 1, width: w, height: h)
		let right = try makePanel(name: "WD19 Right", serial: 2, width: w, height: h)
		panels = [left, right]
		try await waitUntil("virtual displays online", timeout: 5) {
			Set([left.displayID, right.displayID]).isSubset(of: Self.onlineDisplays())
		}
		Log.write("two: panels left=\(left.displayID) right=\(right.displayID)")

		status = "Moving windows…"
		try await gatherWindows(onto: left.displayID)

		status = "Setting up the wide signal…"
		if DisplayModes.current(physical)?.index != wide.index {
			DisplayModes.apply(wide, on: physical, permanently: false)
		}
		try await waitUntil("physical display in wide mode", timeout: 10) {
			DisplayModes.current(physical)?.index == wide.index && Int(CGDisplayPixelsWide(physical)) == wide.width
		}

		status = "Arranging displays…"
		arrange(left: left.displayID, right: right.displayID, width: w, height: h)
		try await waitUntil("arrangement applied", timeout: 6) {
			self.arrangementOK(left: left.displayID, right: right.displayID, width: w, height: h)
		}
		logDisplays("arranged")

		status = "Starting capture…"
		try await waitUntil("screen list updated", timeout: 4) {
			self.screen(for: physical)?.frame.width == CGFloat(wide.width)
		}
		showOverlay()
		try await startCapture(displays: [left.displayID, right.displayID], width: w, height: h)
		startPointerGuard()
		running = true
		status = nil
		Log.write("two: running")
		// Log delivered frames for the first 30 s to diagnose blank panels.
		for t in stride(from: 5, through: 30, by: 5) {
			DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(t)) { [weak self] in
				guard let self, self.running else { return }
				Log.write("two: frames after \(t)s: \(self.frameCounts)")
			}
		}
	}

	func stop() {
		guard running || !panels.isEmpty || overlay != nil else { return }
		Log.write("two: stop")
		guardTimer?.invalidate()
		guardTimer = nil
		for s in streams { s.stopCapture { _ in } }
		streams = []
		outputs = []
		overlay?.orderOut(nil)
		overlay = nil
		layers = []
		if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
		screenObserver = nil
		panels = [] // releasing the objects removes the virtual displays
		running = false
		status = nil
	}

	// MARK: helpers

	private static func onlineDisplays() -> [CGDirectDisplayID] {
		var list = [CGDirectDisplayID](repeating: 0, count: 16)
		var n: UInt32 = 0
		CGGetOnlineDisplayList(16, &list, &n)
		return Array(list.prefix(Int(n)))
	}

	private func waitUntil(_ what: String, timeout: Double, _ ok: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !ok() {
			if Date() > deadline {
				logDisplays("timeout waiting for \(what)")
				throw HubError("Timed out waiting for \(what)")
			}
			try await Task.sleep(nanoseconds: 100_000_000)
		}
		Log.write("two: ok: \(what)")
	}

	func logDisplays(_ tag: String) {
		let main = CGMainDisplayID()
		for id in Self.onlineDisplays() {
			let b = CGDisplayBounds(id)
			let mirror = CGDisplayMirrorsDisplay(id)
			Log.write("two: [\(tag)] display \(id)\(id == main ? " MAIN" : "") bounds=\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)) mirrors=\(mirror) vendor=\(String(CGDisplayVendorNumber(id), radix: 16))")
		}
	}

	// MARK: virtual displays

	private func makePanel(name: String, serial: UInt32, width: Int, height: Int) throws -> CGVirtualDisplay {
		let desc = CGVirtualDisplayDescriptor()
		desc.setDispatchQueue(DispatchQueue.main)
		desc.name = name
		desc.maxPixelsWide = UInt32(width)
		desc.maxPixelsHigh = UInt32(height)
		desc.sizeInMillimeters = CGSize(width: 510, height: 287)
		desc.vendorID = DisplayModes.virtualVendorID
		desc.productID = 0x1900 + serial
		desc.serialNum = serial
		guard let display = CGVirtualDisplay(descriptor: desc) else {
			throw HubError("macOS refused to create a virtual display")
		}
		let settings = CGVirtualDisplaySettings()
		settings.hiDPI = 0
		settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60)]
		guard display.apply(settings) else { throw HubError("could not set the virtual display mode") }
		return display
	}

	/// Mirroring the physical display onto the left panel makes macOS move
	/// every window off it; un-mirroring then leaves them on the panels.
	private func gatherWindows(onto target: CGDirectDisplayID) async throws {
		var cfg: CGDisplayConfigRef?
		CGBeginDisplayConfiguration(&cfg)
		CGConfigureDisplayMirrorOfDisplay(cfg, physical, target)
		let r1 = CGCompleteDisplayConfiguration(cfg, .forSession)
		Log.write("two: mirror physical->left result=\(r1.rawValue)")
		try await waitUntil("mirror on", timeout: 8) { CGDisplayMirrorsDisplay(self.physical) == target }
		try await Task.sleep(nanoseconds: 500_000_000)
		CGBeginDisplayConfiguration(&cfg)
		CGConfigureDisplayMirrorOfDisplay(cfg, physical, kCGNullDirectDisplay)
		let r2 = CGCompleteDisplayConfiguration(cfg, .forSession)
		Log.write("two: unmirror result=\(r2.rawValue)")
		try await waitUntil("mirror off", timeout: 8) { CGDisplayMirrorsDisplay(self.physical) == kCGNullDirectDisplay }
	}

	/// Left panel becomes the main display at (0,0), right panel beside it, the
	/// physical display parked to the right (so both panels keep free top and
	/// bottom edges for the menu bar and the Dock), built-in display (if any) left.
	private func arrange(left: CGDirectDisplayID, right: CGDirectDisplayID, width: Int, height: Int) {
		var cfg: CGDisplayConfigRef?
		CGBeginDisplayConfiguration(&cfg)
		CGConfigureDisplayOrigin(cfg, left, 0, 0)
		CGConfigureDisplayOrigin(cfg, right, Int32(width), 0)
		CGConfigureDisplayOrigin(cfg, physical, Int32(width * 2), 0)
		if let builtin = Self.onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
			CGConfigureDisplayOrigin(cfg, builtin, -Int32(CGDisplayPixelsWide(builtin)), 0)
		}
		let r = CGCompleteDisplayConfiguration(cfg, .forSession)
		Log.write("two: arrange result=\(r.rawValue)")
	}

	private func arrangementOK(left: CGDirectDisplayID, right: CGDirectDisplayID, width: Int, height: Int) -> Bool {
		let l = CGDisplayBounds(left), r = CGDisplayBounds(right), p = CGDisplayBounds(physical)
		return CGMainDisplayID() == left
			&& l.origin == .zero
			&& r.origin == CGPoint(x: width, y: 0)
			&& p.minX >= r.maxX
			&& !p.intersects(l) && !p.intersects(r)
	}

	// MARK: overlay + capture

	private func screen(for id: CGDirectDisplayID) -> NSScreen? {
		NSScreen.screens.first {
			($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
		}
	}

	private func showOverlay() {
		guard let scr = screen(for: physical) else { return }
		let w = NSWindow(contentRect: scr.frame, styleMask: .borderless, backing: .buffered, defer: false)
		w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
		w.backgroundColor = .black
		w.ignoresMouseEvents = true
		w.isReleasedWhenClosed = false
		w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
		w.setFrame(scr.frame, display: false)
		let root = CALayer()
		root.backgroundColor = NSColor.black.cgColor
		w.contentView?.wantsLayer = true
		w.contentView?.layer = root
		layers = (0..<2).map { _ in
			let l = CALayer()
			l.contentsGravity = .resize
			l.actions = ["contents": NSNull()]
			root.addSublayer(l)
			return l
		}
		overlay = w
		layoutLayers()
		w.orderFrontRegardless()
		Log.write("two: overlay frame=\(scr.frame)")
		screenObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, let scr = self.screen(for: self.physical) else { return }
				self.overlay?.setFrame(scr.frame, display: true)
				self.layoutLayers()
				Log.write("two: screens changed, overlay frame=\(scr.frame)")
			}
		}
	}

	private func layoutLayers() {
		guard layers.count == 2, let bounds = overlay?.contentView?.bounds else { return }
		let half = bounds.width / 2
		let leftFrame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
		let rightFrame = CGRect(x: half, y: 0, width: half, height: bounds.height)
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layers[0].frame = swapSides ? rightFrame : leftFrame
		layers[1].frame = swapSides ? leftFrame : rightFrame
		CATransaction.commit()
	}

	private func startCapture(displays: [CGDirectDisplayID], width: Int, height: Int) async throws {
		let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
		for (i, id) in displays.enumerated() {
			guard let scd = content.displays.first(where: { $0.displayID == id }) else {
				throw HubError("virtual display \(i + 1) is not capturable")
			}
			let cfg = SCStreamConfiguration()
			cfg.width = width
			cfg.height = height
			cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
			cfg.pixelFormat = kCVPixelFormatType_32BGRA
			cfg.showsCursor = true
			cfg.queueDepth = 4
			let stream = SCStream(filter: SCContentFilter(display: scd, excludingWindows: []), configuration: cfg, delegate: nil)
			let out = PanelOutput(layer: layers[i], index: i)
			try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "wd19split.panel\(i)"))
			try await stream.startCapture()
			streams.append(stream)
			outputs.append(out)
			Log.write("two: capture started for panel \(i) (display \(id))")
		}
	}

	var frameCounts: [Int] { outputs.map(\.frames) }

	// MARK: pointer guard

	/// Keep the pointer on the virtual panels: if it lands on the physical
	/// display (hidden under the overlay), put it back just above. Switches
	/// itself off if it has to act too often, so it can never trap the pointer.
	private func startPointerGuard() {
		let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.guardTick() }
		}
		// Common modes so it keeps running while a modal prompt is up.
		RunLoop.main.add(t, forMode: .common)
		guardTimer = t
	}

	private func guardTick() {
		guard panels.count == 2 else { return }
		let left = panels[0].displayID, right = panels[1].displayID
		// Only act while the layout is the one we set up; if something else
		// rearranged the displays, stand down instead of fighting it.
		guard arrangementOK(left: left, right: right, width: Int(panelSize.width), height: Int(panelSize.height)) else {
			guardTimer?.invalidate()
			guardTimer = nil
			Log.write("two: pointer guard off: display arrangement changed")
			logDisplays("guard-off")
			status = "Displays were rearranged; choose Two displays again to restore."
			return
		}
		guard let loc = CGEvent(source: nil)?.location else { return }
		let b = CGDisplayBounds(physical)
		guard b.contains(loc) else { return }
		// Back onto the right edge of the right panel, same height.
		let r = CGDisplayBounds(right)
		let y = min(max(loc.y, r.minY), r.maxY - 1)
		CGWarpMouseCursorPosition(CGPoint(x: r.maxX - 1, y: y))
		CGAssociateMouseAndMouseCursorPosition(1)
	}
}

/// Receives frames for one panel and hands the IOSurface straight to a layer.
private final class PanelOutput: NSObject, SCStreamOutput, @unchecked Sendable {
	private let layer: CALayer
	private let index: Int
	private(set) var frames = 0

	init(layer: CALayer, index: Int) {
		self.layer = layer
		self.index = index
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen, sb.isValid,
		      let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
		      let raw = attachments.first?[.status] as? Int,
		      SCFrameStatus(rawValue: raw) == .complete,
		      let pb = CMSampleBufferGetImageBuffer(sb),
		      let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
		frames += 1
		// Update the layer right here on the capture queue (explicit transaction)
		// rather than hopping to the main thread, so a busy or modal main thread
		// can never freeze the panels or the pointer drawn inside them.
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer.contents = surface
		CATransaction.commit()
		CATransaction.flush()
	}
}
