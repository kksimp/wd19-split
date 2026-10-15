// dispmode: list / set display modes on the external display, with auto-revert.
//   dispmode list
//   dispmode set <width> <height> [revert-after-seconds]   (default revert 20s; 0 = keep)
// build: swiftc -O -o dispmode dispmode.swift

import CoreGraphics
import Foundation

func externalDisplay() -> CGDirectDisplayID? {
	var ids = [CGDirectDisplayID](repeating: 0, count: 16)
	var n: UInt32 = 0
	CGGetOnlineDisplayList(16, &ids, &n)
	return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) == 0 }
}

func modes(_ d: CGDirectDisplayID) -> [CGDisplayMode] {
	let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
	return (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []
}

func describe(_ m: CGDisplayMode) -> String {
	"\(m.pixelWidth)x\(m.pixelHeight) (UI \(m.width)x\(m.height)) @ \(String(format: "%.2f", m.refreshRate))Hz usable=\(m.isUsableForDesktopGUI())"
}

let args = CommandLine.arguments
guard let d = externalDisplay() else { fputs("no external display\n", stderr); exit(1) }
let current = CGDisplayCopyDisplayMode(d)!
print("display \(d) current: \(describe(current))")

if args.count >= 2 && args[1] == "list" {
	var seen = Set<String>()
	for m in modes(d) where seen.insert(describe(m)).inserted { print("  " + describe(m)) }
} else if args.count >= 4 && args[1] == "set", let w = Int(args[2]), let h = Int(args[3]) {
	let revert = args.count >= 5 ? (Int(args[4]) ?? 20) : 20
	// match on the wire size; prefer an unscaled (1x) mode, else accept a HiDPI one
	let cands = modes(d).filter { $0.pixelWidth == w && $0.pixelHeight == h && $0.isUsableForDesktopGUI() }
	guard let m = cands.first(where: { $0.width == w }) ?? cands.first else {
		fputs("mode \(w)x\(h) not offered\n", stderr); exit(1)
	}
	var cfg: CGDisplayConfigRef?
	CGBeginDisplayConfiguration(&cfg)
	CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
	let r = CGCompleteDisplayConfiguration(cfg, revert > 0 ? .forSession : .permanently)
	print("set \(describe(m)) -> \(r == .success ? "ok" : "error \(r.rawValue)")")
	if revert > 0 {
		print("reverting to \(describe(current)) in \(revert)s (Ctrl-C keeps the new mode for this session)")
		sleep(UInt32(revert))
		CGBeginDisplayConfiguration(&cfg)
		CGConfigureDisplayWithDisplayMode(cfg, d, current, nil)
		CGCompleteDisplayConfiguration(cfg, .forSession)
		print("reverted")
	}
} else {
	print("usage: dispmode list | dispmode set <w> <h> [revert-seconds]")
}
