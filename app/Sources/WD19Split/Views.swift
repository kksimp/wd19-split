import SwiftUI

struct MenuView: View {
	@EnvironmentObject var model: AppModel
	@EnvironmentObject var hub: HubController

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			header
			Divider()
			if hub.state.supported {
				layoutPicker
				if model.layout == .twoDisplays {
					TwoDisplayOptions(two: model.two)
				}
				status
			} else if hub.state.connected {
				Label(hub.state.unsupportedReason, systemImage: "exclamationmark.triangle")
					.foregroundStyle(.secondary)
			}
			if let msg = model.message {
				Text(msg).font(.caption).foregroundStyle(.red)
			}
			Divider()
			HStack {
				Button("Refresh") { hub.refresh() }.disabled(hub.busy)
				Button("Restore Dell defaults") { model.restoreDefaults() }
					.disabled(!hub.state.supported || hub.busy)
				Spacer()
				if hub.busy { ProgressView().controlSize(.small) }
			}
			HStack {
				SettingsLink { Text("Settings…") }
				Spacer()
				Button("Quit") { NSApp.terminate(nil) }
			}
		}
		.padding(14)
		.frame(width: 320)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(hub.state.connected ? "Dell \(hub.state.name)" : "No WD19 dock connected")
				.font(.headline)
			if hub.state.connected {
				Text("Service tag \(hub.state.serviceTag) · hub firmware \(hub.state.mstVersion)")
					.font(.caption).foregroundStyle(.secondary)
				Text("\(hub.state.monitors) monitor\(hub.state.monitors == 1 ? "" : "s") on the dock · \(model.displayDescription)")
					.font(.caption).foregroundStyle(.secondary)
			}
		}
	}

	private var layoutPicker: some View {
		Picker("Layout", selection: Binding(get: { model.layout }, set: { model.choose($0) })) {
			ForEach(Layout.allCases) { l in
				Text(l.title).tag(l)
			}
		}
		.pickerStyle(.segmented)
		.labelsHidden()
		.disabled(hub.busy)
	}

	@ViewBuilder private var status: some View {
		let s = hub.state
		if s.needsReplug {
			Label("Unplug one monitor at the dock and plug it back in to finish switching.",
			      systemImage: "cable.connector")
				.font(.callout)
		} else if s.splitEnabled && s.monitors < 2 {
			Label("Split needs two monitors on the dock.", systemImage: "display.2")
				.font(.callout)
		} else if s.splitEnabled {
			Label("Dock is splitting one wide picture across both monitors.", systemImage: "checkmark.circle")
				.font(.callout)
		} else {
			Label("Dock is mirroring (Dell default).", systemImage: "rectangle.on.rectangle")
				.font(.callout)
		}
	}
}

/// Options shown while the "Two displays" layout is selected.
struct TwoDisplayOptions: View {
	@EnvironmentObject var model: AppModel
	@ObservedObject var two: TwoDisplayController

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Toggle("Swap sides", isOn: Binding(get: { model.swapSides }, set: { model.setSwapSides($0) }))
			if let s = two.status {
				Label(s, systemImage: "hourglass").font(.caption)
			} else if two.running {
				Text("macOS sees two separate monitors. Protected video (e.g. streaming services) shows black in this layout; use Ultrawide for it.")
					.font(.caption).foregroundStyle(.secondary)
			}
		}
	}
}

struct SettingsView: View {
	@EnvironmentObject var model: AppModel

	var body: some View {
		Form {
			Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
			Toggle("Apply my layout when the dock connects", isOn: model.$applyOnConnect)
			Toggle("Use HiDPI (scaled 2×) for the ultrawide layout", isOn: model.$hiDPI)
			Text("The dock forgets split mode when its power is unplugged. With the first option on, this app sets it again each time the dock connects; you may need to replug one monitor once to finish.")
				.font(.caption).foregroundStyle(.secondary)
			Text("What this app changes: one setting in the hub's RAM (the display mode), and your Mac's resolution. It never writes the dock's firmware and does not touch HDCP or other content protection.")
				.font(.caption).foregroundStyle(.secondary)
		}
		.formStyle(.grouped)
		.frame(width: 440)
		.padding()
	}
}
