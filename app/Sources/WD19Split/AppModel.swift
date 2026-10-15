import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

enum Layout: String, CaseIterable, Identifiable {
	case mirror, ultrawide, twoDisplays
	var id: String { rawValue }
	var title: String {
		switch self {
		case .mirror: "Mirror"
		case .ultrawide: "Ultrawide"
		case .twoDisplays: "Two displays"
		}
	}
	var wantsSplit: Bool { self != .mirror }
}

/// Coordinates the user's layout choice with the hub mode, the macOS display
/// mode and (for "Two displays") the virtual panels. Hub writes and display
/// changes only happen in response to a user choice or the dock connecting
/// (if "apply on connect" is on and a layout was chosen before).
@MainActor
final class AppModel: ObservableObject {
	@AppStorage("layout") var layout: Layout = .mirror
	@AppStorage("applyOnConnect") var applyOnConnect = true
	@AppStorage("hiDPI") var hiDPI = false
	@AppStorage("swapSides") var swapSides = false
	/// Nothing is applied automatically until the user has picked a layout once.
	@AppStorage("hasChosenLayout") var hasChosenLayout = false

	@Published private(set) var displayDescription = "No external display"
	@Published private(set) var message: String?

	let hub = HubController()
	let two = TwoDisplayController()

	/// Set when the hub mode should be brought in line with `layout`.
	private var enforceHubMode = false
	/// Set when the next display change came from the user and needs a
	/// "keep this layout?" confirmation.
	private var confirmNextDisplayChange = false
	/// Layout to go back to if the user reverts.
	private var previousLayout: Layout = .mirror
	private var twoStarting = false
	/// While a self-test runs it owns the displays; normal reconciliation pauses.
	private var selfTesting = false
	private var hubObserver: Any?

	init() {
		hub.onAttach = { [weak self] in
			guard let self, self.applyOnConnect, self.hasChosenLayout else { return }
			self.enforceHubMode = true
		}
		hubObserver = hub.$state.sink { [weak self] s in
			DispatchQueue.main.async { self?.hubChanged(s) }
		}
		CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
			guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
			let me = Unmanaged<AppModel>.fromOpaque(ctx).takeUnretainedValue()
			DispatchQueue.main.async { me.displaysChanged() }
		}, Unmanaged.passUnretained(self).toOpaque())
		two.swapSides = swapSides
		updateDisplayDescription()
	}

	// MARK: user actions

	func choose(_ new: Layout) {
		guard new != layout || !hasChosenLayout else { return }
		if new == .twoDisplays && !TwoDisplayController.hasCapturePermission {
			TwoDisplayController.requestCapturePermission()
			message = "Allow WD19 Split under System Settings → Privacy & Security → Screen & System Audio Recording, then choose Two displays again."
			return
		}
		message = nil
		previousLayout = layout
		layout = new
		hasChosenLayout = true
		enforceHubMode = true
		confirmNextDisplayChange = true
		hub.refresh()
	}

	func setSwapSides(_ on: Bool) {
		swapSides = on
		two.swapSides = on
	}

	/// Start the app when you log in (registered with macOS Login Items).
	var openAtLogin: Bool {
		get { SMAppService.mainApp.status == .enabled }
		set {
			do {
				if newValue {
					try SMAppService.mainApp.register()
				} else {
					try SMAppService.mainApp.unregister()
				}
			} catch {
				message = "Open at login: \(error.localizedDescription)"
			}
			objectWillChange.send()
		}
	}

	func restoreDefaults() {
		previousLayout = layout
		layout = .mirror
		hasChosenLayout = true
		enforceHubMode = true
		confirmNextDisplayChange = false
		hub.refresh()
	}

	// MARK: reconciliation

	private func hubChanged(_ s: HubState) {
		if let e = s.error { message = e }
		guard s.connected, s.supported else {
			if two.running { two.stop() }
			return
		}
		if enforceHubMode, s.splitEnabled != layout.wantsSplit {
			enforceHubMode = false
			hub.setSplit(layout.wantsSplit)
			return
		}
		enforceHubMode = false
		if hasChosenLayout {
			reconcileDisplay()
		}
	}

	private var displayDebounce: DispatchWorkItem?

	private func displaysChanged() {
		updateDisplayDescription()
		// The two-display layout reconfigures displays itself; ignore those.
		guard !twoStarting, !selfTesting else { return }
		// A replug changes the EDID: re-read the hub, which then reconciles.
		displayDebounce?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.hub.refresh() }
		displayDebounce = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
	}

	private func reconcileDisplay() {
		guard !selfTesting else { return }
		if layout != .twoDisplays && two.running {
			two.stop()
		}
		// While active, the two-display controller owns the display setup.
		guard !twoStarting, !two.running else { return }
		guard let d = DisplayModes.externalDisplay(), let cur = DisplayModes.current(d) else { return }

		let wantsWide = layout.wantsSplit && hub.state.advertisingWide
		let target: DisplayMode?
		if wantsWide {
			target = DisplayModes.wideMode(d, hiDPI: layout == .ultrawide && hiDPI)
		} else if layout == .mirror && DisplayModes.isWide(cur) {
			target = DisplayModes.singleMode(d)
		} else {
			target = nil
		}
		let confirm = confirmNextDisplayChange
		let previous = cur

		if layout == .twoDisplays {
			// Wait until the hub advertises the wide timing (may need a replug).
			guard let target else { return }
			confirmNextDisplayChange = false
			if target.index != cur.index {
				DisplayModes.apply(target, on: d, permanently: false)
			}
			startTwoDisplays(physical: d, wide: target, previous: previous, confirm: confirm)
			return
		}

		guard let target, target.index != cur.index else { return }
		confirmNextDisplayChange = false
		DisplayModes.apply(target, on: d, permanently: !confirm)
		updateDisplayDescription()
		guard confirm else { return }
		KeepDialog.ask(title: "Keep this display layout?",
			       detail: "Now \(target). Reverting to \(previous) in 15 seconds.",
			       seconds: 15) { keep in
			DisplayModes.apply(keep ? target : previous, on: d, permanently: true)
			if !keep { self.revertLayout() }
			self.updateDisplayDescription()
		}
	}

	private func startTwoDisplays(physical d: CGDirectDisplayID, wide: DisplayMode, previous: DisplayMode, confirm: Bool) {
		twoStarting = true
		two.swapSides = swapSides
		Task { @MainActor in
			do {
				try await two.start(physical: d, wide: wide)
			} catch {
				Log.write("two: failed: \(error)")
				two.stop()
				twoStarting = false
				message = "\(error)"
				DisplayModes.apply(previous, on: d, permanently: true)
				revertLayout()
				return
			}
			twoStarting = false
			updateDisplayDescription()
			guard confirm else { return }
			KeepDialog.ask(title: "Keep two displays?",
				       detail: "Reverting in 15 seconds if you don't choose Keep.",
				       seconds: 15) { keep in
				guard !keep else { return }
				self.two.stop()
				DisplayModes.apply(previous, on: d, permanently: true)
				self.revertLayout()
			}
		}
	}

	/// Diagnostic run (launched with `--selftest-two N`): turn on the layout
	/// without prompts, record state, a frame count and a picture of what the
	/// dock receives into the log folder, then undo everything and quit.
	func selfTestTwo(seconds: Int) {
		Task { @MainActor in
			selfTesting = true
			Log.write("selftest: begin (\(seconds)s)")
			let logs = Log.url.deletingLastPathComponent()
			defer {
				Log.write("selftest: end")
				DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
			}
			guard let d = DisplayModes.externalDisplay(), let cur = DisplayModes.current(d),
			      let wide = DisplayModes.wideMode(d, hiDPI: false) else {
				Log.write("selftest: no external display with a wide mode")
				return
			}
			let hubWasSplit = hub.state.splitEnabled
			if !hubWasSplit { hub.setSplit(true) }
			try? await Task.sleep(nanoseconds: 2_000_000_000)
			two.logDisplays("before")
			do {
				try await two.start(physical: d, wide: wide)
				try? await Task.sleep(nanoseconds: 3_000_000_000)
				two.logDisplays("running")
				Log.write("selftest: frames per panel after 3s: \(two.frameCounts)")
				await Self.snapshot(display: d, to: logs.appendingPathComponent("WD19Split-physical.png"))
				for (i, id) in two.panelIDs.enumerated() {
					await Self.snapshot(display: id, to: logs.appendingPathComponent("WD19Split-panel\(i).png"))
				}
				Self.logDockWindows()
				// The pointer must not stay on the hidden wide display.
				let pb = CGDisplayBounds(d)
				CGWarpMouseCursorPosition(CGPoint(x: pb.midX, y: pb.midY))
				try? await Task.sleep(nanoseconds: 300_000_000)
				let loc = CGEvent(source: nil)?.location ?? .zero
				Log.write("selftest: pointer put at \(pb.midX),\(pb.midY) -> now \(loc) (on hidden display: \(pb.contains(loc)))")
				// The keep prompt must not stall the panels: frames have to keep
				// arriving while it is on screen.
				let before = two.frameCounts
				KeepDialog.ask(title: "Self-test prompt", detail: "Frames must keep updating behind this.", seconds: 8) { _ in }
				try? await Task.sleep(nanoseconds: 6_000_000_000)
				Log.write("selftest: frames during prompt: \(before) -> \(two.frameCounts)")
				try? await Task.sleep(nanoseconds: UInt64(max(seconds - 9, 1)) * 1_000_000_000)
				Log.write("selftest: frames per panel at end: \(two.frameCounts)")
			} catch {
				Log.write("selftest: start failed: \(error)")
			}
			two.stop()
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			DisplayModes.apply(cur, on: d, permanently: true)
			if !hubWasSplit && !layout.wantsSplit { hub.setSplit(false) }
			two.logDisplays("after")
		}
	}

	/// Log where the Dock's windows are and which display each one is on.
	private static func logDockWindows() {
		let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
		for w in list where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
			guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
			      let r = CGRect(dictionaryRepresentation: bd),
			      (w[kCGWindowName as String] as? String) == "Dock" else { continue }
			var id: CGDirectDisplayID = 0
			var n: UInt32 = 0
			CGGetDisplaysWithPoint(CGPoint(x: r.midX, y: r.midY), 1, &id, &n)
			Log.write("selftest: Dock window \(r) on display \(id)")
		}
	}

	private static func snapshot(display: CGDirectDisplayID, to url: URL) async {
		do {
			let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
			guard let scd = content.displays.first(where: { $0.displayID == display }) else {
				Log.write("selftest: display \(display) not capturable")
				return
			}
			let cfg = SCStreamConfiguration()
			cfg.width = scd.width
			cfg.height = scd.height
			let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: scd, excludingWindows: []), configuration: cfg)
			let rep = NSBitmapImageRep(cgImage: img)
			try rep.representation(using: .png, properties: [:])?.write(to: url)
			Log.write("selftest: saved \(url.lastPathComponent) \(img.width)x\(img.height)")
		} catch {
			Log.write("selftest: snapshot of \(display) failed: \(error)")
		}
	}

	/// Go back to the layout chosen before the one being reverted.
	private func revertLayout() {
		layout = previousLayout
		enforceHubMode = true
		hub.refresh()
	}

	private func updateDisplayDescription() {
		if let d = DisplayModes.externalDisplay(), let m = DisplayModes.current(d) {
			displayDescription = two.running ? "two panels on \(m)" : "\(m)"
		} else {
			displayDescription = "No external display"
		}
	}
}

/// Floating "keep / revert" panel that reverts on its own after a timeout,
/// like the prompt System Settings shows for resolution changes. It is not
/// modal: the main thread keeps running while it is up.
@MainActor
enum KeepDialog {
	private static var panel: NSPanel?

	static func ask(title: String, detail: String, seconds: Int, done: @escaping (Bool) -> Void) {
		panel?.close()
		var finished = false
		var remaining = seconds
		let finish: (Bool) -> Void = { keep in
			guard !finished else { return }
			finished = true
			Log.write("keep prompt: \(keep ? "keep" : "revert")")
			panel?.close()
			panel = nil
			done(keep)
		}

		let countdown = NSTextField(labelWithString: "")
		let keep = NSButton(title: "Keep", target: nil, action: nil)
		keep.keyEquivalent = "\r"
		let revert = NSButton(title: "Revert", target: nil, action: nil)
		let handler = ButtonHandler { finish($0 === keep) }
		keep.target = handler
		keep.action = #selector(ButtonHandler.clicked(_:))
		revert.target = handler
		revert.action = #selector(ButtonHandler.clicked(_:))

		let heading = NSTextField(labelWithString: title)
		heading.font = .boldSystemFont(ofSize: 13)
		let body = NSTextField(wrappingLabelWithString: detail)
		let buttons = NSStackView(views: [revert, keep])
		let stack = NSStackView(views: [heading, body, countdown, buttons])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)

		let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
				styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow],
				backing: .buffered, defer: false)
		p.title = "WD19 Split"
		p.level = .floating
		p.isReleasedWhenClosed = false
		p.contentView = stack
		objc_setAssociatedObject(p, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
		if let main = NSScreen.screens.first {
			let f = main.visibleFrame
			p.setFrameOrigin(NSPoint(x: f.midX - 180, y: f.midY))
		}
		panel = p
		p.orderFrontRegardless()

		let update = { countdown.stringValue = "Reverting in \(remaining) s" }
		update()
		let timer = Timer(timeInterval: 1, repeats: true) { t in
			MainActor.assumeIsolated {
				remaining -= 1
				update()
				if remaining <= 0 || finished {
					t.invalidate()
					finish(false)
				}
			}
		}
		RunLoop.main.add(timer, forMode: .common)
	}

	private final class ButtonHandler: NSObject {
		let action: (NSButton) -> Void
		init(_ action: @escaping (NSButton) -> Void) { self.action = action }
		@objc func clicked(_ sender: NSButton) { action(sender) }
	}
}
