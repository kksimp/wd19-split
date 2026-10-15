import CoreGraphics
import Foundation

/// One entry of the window server's full mode table for a display. The public
/// CGDisplayCopyAllDisplayModes hides some modes (e.g. the unscaled 3840x1080
/// the dock advertises), so we read the private table that System Settings uses.
struct DisplayMode: Hashable, CustomStringConvertible {
	let index: Int32
	let width: Int
	let height: Int
	let refresh: Int
	let density: Float
	let flags: UInt32

	var isHiDPI: Bool { density > 1.5 }
	var description: String {
		"\(width)×\(height)\(isHiDPI ? " HiDPI" : "") @ \(refresh) Hz"
	}
}

/// Thin wrapper over the SkyLight mode functions, resolved at runtime.
enum DisplayModes {
	private typealias NumFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
	private typealias DescFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Int32
	private typealias CurFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
	private typealias CfgFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> Int32

	private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
	private static func sym<T>(_ name: String, _: T.Type) -> T? {
		guard let lib, let p = dlsym(lib, name) else { return nil }
		return unsafeBitCast(p, to: T.self)
	}
	private static let numFn = sym("CGSGetNumberOfDisplayModes", NumFn.self)
	private static let descFn = sym("CGSGetDisplayModeDescriptionOfLength", DescFn.self)
	private static let curFn = sym("CGSGetCurrentDisplayMode", CurFn.self)
	private static let cfgFn = sym("CGSConfigureDisplayMode", CfgFn.self)

	// Layout of the 212-byte mode description record.
	private static let recordSize = 212

	static var available: Bool { numFn != nil && descFn != nil && curFn != nil && cfgFn != nil }

	/// Vendor ID of the virtual panels this app creates ("WD").
	static let virtualVendorID: UInt32 = 0x5744

	/// The first online physical external display (not built-in, not one of
	/// our virtual panels).
	static func externalDisplay() -> CGDirectDisplayID? {
		var ids = [CGDirectDisplayID](repeating: 0, count: 16)
		var n: UInt32 = 0
		CGGetOnlineDisplayList(16, &ids, &n)
		return ids.prefix(Int(n)).first {
			CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != virtualVendorID
		}
	}

	static func all(_ d: CGDirectDisplayID) -> [DisplayMode] {
		guard let numFn, let descFn else { return [] }
		var count: Int32 = 0
		_ = numFn(d, &count)
		let buf = UnsafeMutableRawPointer.allocate(byteCount: recordSize, alignment: 4)
		defer { buf.deallocate() }
		var out: [DisplayMode] = []
		for i in 0..<count {
			memset(buf, 0, recordSize)
			_ = descFn(d, i, buf, Int32(recordSize))
			out.append(DisplayMode(
				index: i,
				width: Int(buf.load(fromByteOffset: 8, as: UInt32.self)),
				height: Int(buf.load(fromByteOffset: 12, as: UInt32.self)),
				refresh: Int(buf.load(fromByteOffset: 190, as: UInt16.self)),
				density: buf.load(fromByteOffset: 208, as: Float.self),
				flags: buf.load(fromByteOffset: 4, as: UInt32.self)))
		}
		return out
	}

	static func current(_ d: CGDirectDisplayID) -> DisplayMode? {
		guard let curFn else { return nil }
		var idx: Int32 = -1
		_ = curFn(d, &idx)
		return all(d).first { $0.index == idx }
	}

	/// Side-by-side panels show up as a mode wider than 2.5:1.
	static func isWide(_ m: DisplayMode) -> Bool { Double(m.width) / Double(max(m.height, 1)) > 2.5 }

	/// The dock's combined mode (two panels side by side), unscaled unless
	/// HiDPI is requested (HiDPI entries report their size in points).
	static func wideMode(_ d: CGDirectDisplayID, hiDPI: Bool) -> DisplayMode? {
		all(d)
			.filter { isWide($0) && $0.isHiDPI == hiDPI }
			.max { ($0.width, $0.refresh) < ($1.width, $1.refresh) }
	}

	/// The display's single-panel native mode (largest unscaled, non-wide mode).
	static func singleMode(_ d: CGDirectDisplayID) -> DisplayMode? {
		all(d)
			.filter { !$0.isHiDPI && !isWide($0) }
			.max { ($0.width * $0.height, $0.refresh) < ($1.width * $1.height, $1.refresh) }
	}

	@discardableResult
	static func apply(_ mode: DisplayMode, on d: CGDirectDisplayID, permanently: Bool) -> Bool {
		guard let cfgFn else { return false }
		var cfg: CGDisplayConfigRef?
		guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
		_ = cfgFn(cfg, d, mode.index)
		return CGCompleteDisplayConfiguration(cfg, permanently ? .permanently : .forSession) == .success
	}
}
