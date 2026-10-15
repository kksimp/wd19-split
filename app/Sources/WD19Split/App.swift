import AppKit
import SwiftUI

@main
struct WD19SplitApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	var body: some Scene {
		// Extra entry point; macOS may hide it when the menu bar is full or the
		// app is not allowed there, so the main window below is the primary UI.
		MenuBarExtra("WD19 Split", systemImage: "rectangle.split.2x1") {
			MenuView()
				.environmentObject(delegate.model)
				.environmentObject(delegate.model.hub)
		}
		.menuBarExtraStyle(.window)

		Settings {
			SettingsView().environmentObject(delegate.model)
		}
	}
}

/// Owns the model and a plain AppKit window that opens at launch and whenever
/// the app is opened again (Finder, Dock, `open`), so the controls are always
/// reachable even if the menu bar item is hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	let model = AppModel()
	private var window: NSWindow?

	func applicationDidFinishLaunching(_ notification: Notification) {
		Log.write("launch \(CommandLine.arguments.dropFirst().joined(separator: " "))")
		// Look for an already-connected dock right away; hot-plugs are handled
		// by the HID watcher in HubController.
		model.hub.refresh()
		let args = CommandLine.arguments
		if let i = args.firstIndex(of: "--selftest-two") {
			let seconds = i + 1 < args.count ? Int(args[i + 1]) ?? 20 : 20
			DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.model.selfTestTwo(seconds: seconds) }
			return
		}
		showWindow()
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		showWindow()
		return true
	}

	func showWindow() {
		if window == nil {
			let root = MenuView()
				.environmentObject(model)
				.environmentObject(model.hub)
			let w = NSWindow(contentViewController: NSHostingController(rootView: root))
			w.title = "WD19 Split"
			w.styleMask = [.titled, .closable, .miniaturizable]
			w.isReleasedWhenClosed = false
			w.center()
			window = w
		}
		NSApp.activate(ignoringOtherApps: true)
		window?.makeKeyAndOrderFront(nil)
	}
}
