import DockCore
import Foundation
import IOKit.hid

/// Snapshot of the dock and its MST hub.
struct HubState: Equatable {
	var connected = false
	var name = ""
	var serviceTag = ""
	var mstVersion = ""
	var supported = false
	var unsupportedReason = ""
	var monitors = 0
	var edidMode: UInt8?
	/// The hub is currently advertising a side-by-side (aggregate) timing.
	var advertisingWide = false
	var error: String?

	var splitEnabled: Bool { edidMode == UInt8(DC_EDID_MODE_AGGREGATE) }
	/// Split is set in the hub but it has not rebuilt the EDID yet (needs a
	/// downstream hot-plug: replug one monitor at the dock).
	var needsReplug: Bool { splitEnabled && !advertisingWide && monitors >= 2 }
}

/// Talks to the dock through DockCore on a private serial queue and publishes
/// state on the main thread. Each operation opens the HID bridge, does its work
/// and closes it again, which also restores the EC bus lock.
@MainActor
final class HubController: ObservableObject {
	@Published private(set) var state = HubState()
	@Published private(set) var busy = false

	/// Hub firmware builds whose RAM layout we have verified (see research/).
	nonisolated static let verifiedMSTVersions: Set<String> = ["05.06.03"]
	/// First bytes of the config block (flash 0x100) on verified builds; checked
	/// in hub RAM at 0x1700 before any write.
	nonisolated static let configSignature: [UInt8] = [0x20, 0x00, 0x83, 0x83]

	var onAttach: (() -> Void)?

	private let queue = DispatchQueue(label: "wd19split.hub")
	private var hidManager: IOHIDManager?

	init() {
		watchForDock()
	}

	// MARK: actions

	func refresh() {
		run { h in try Self.readState(h) }
	}

	/// Turn split mode on (aggregate EDID) or off (Dell's pass-through default).
	func setSplit(_ on: Bool) {
		run { h in
			var s = try Self.readState(h)
			guard s.supported else { throw HubError(s.unsupportedReason) }
			let mode = UInt8(on ? DC_EDID_MODE_AGGREGATE : DC_EDID_MODE_PASSTHROUGH)
			guard dc_mst_set_edid_mode(h, mode, nil, nil) == 0 else { throw HubError(h) }
			s = try Self.readState(h)
			return s
		}
	}

	// MARK: plumbing

	private func run(_ work: @escaping (OpaquePointer) throws -> HubState) {
		busy = true
		queue.async {
			var result: HubState
			var handle: OpaquePointer?
			if dc_open(&handle) != 0 {
				result = HubState(connected: false, error: String(cString: dc_last_error(handle)))
			} else {
				do {
					result = try work(handle!)
				} catch {
					result = (try? Self.readState(handle!)) ?? HubState(connected: true)
					result.error = "\(error)"
				}
			}
			dc_close(handle)
			DispatchQueue.main.async {
				self.state = result
				self.busy = false
			}
		}
	}

	private nonisolated static func readState(_ h: OpaquePointer) throws -> HubState {
		var s = HubState(connected: true)
		var info = dc_dock_info()
		guard dc_dock_info_read(h, &info) == 0 else { throw HubError(h) }
		s.name = withUnsafeBytes(of: info.marketing_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
		s.serviceTag = withUnsafeBytes(of: info.service_tag) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
		if info.has_mst_version != 0 {
			let v = info.mst_version
			s.mstVersion = String(format: "%02x.%02x.%02x", v.0, v.1, v.2)
		}

		guard info.base_type == 0x04 else {
			s.unsupportedReason = "Not a WD19-family dock"
			return s
		}
		guard verifiedMSTVersions.contains(s.mstVersion) else {
			s.unsupportedReason = "Hub firmware \(s.mstVersion) has not been verified"
			return s
		}

		// One read covers EDID page 0x1600, config 0x1700 and port state 0x1820.
		var mem = [UInt8](repeating: 0, count: 0x230)
		guard dc_mst_read_memory(h, UInt32(DC_RAM_EDID), UInt32(mem.count), &mem) == 0 else { throw HubError(h) }
		let cfg = Array(mem[0x100..<0x104])
		guard cfg == configSignature else {
			s.unsupportedReason = "Hub RAM layout does not match the verified build"
			return s
		}
		s.supported = true
		s.edidMode = mem[0x140] & 0x0f
		s.monitors = Int(mem[0x221] & 0x0f)
		s.advertisingWide = edidHasWideTiming(Array(mem[0..<128]))
		return s
	}

	/// True if any detailed timing descriptor in the EDID is wider than 2.5:1.
	private nonisolated static func edidHasWideTiming(_ e: [UInt8]) -> Bool {
		for off in stride(from: 54, to: 126, by: 18) where e[off] != 0 || e[off + 1] != 0 {
			let w = Int(e[off + 2]) | Int(e[off + 4] >> 4) << 8
			let h = Int(e[off + 5]) | Int(e[off + 7] >> 4) << 8
			if h > 0 && Double(w) / Double(h) > 2.5 { return true }
		}
		return false
	}

	/// Re-read state whenever the dock's HID bridge appears or disappears.
	private func watchForDock() {
		let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
		IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x413c, kIOHIDProductIDKey: 0xb06e] as CFDictionary)
		let ctx = Unmanaged.passUnretained(self).toOpaque()
		IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, _ in
			let me = Unmanaged<HubController>.fromOpaque(ctx!).takeUnretainedValue()
			// The dock's EC needs a few seconds after enumeration.
			DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
				me.refresh()
				me.onAttach?()
			}
		}, ctx)
		IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
			let me = Unmanaged<HubController>.fromOpaque(ctx!).takeUnretainedValue()
			DispatchQueue.main.async { me.state = HubState() }
		}, ctx)
		IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
		IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
		hidManager = mgr
	}
}

struct HubError: Error, CustomStringConvertible {
	let description: String
	init(_ message: String) { description = message }
	init(_ h: OpaquePointer) { description = String(cString: dc_last_error(h)) }
}
