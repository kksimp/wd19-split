// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "WD19Split",
	platforms: [.macOS(.v14)],
	targets: [
		.target(
			name: "DockCore",
			path: "Sources/DockCore",
			publicHeadersPath: "include",
			linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
		),
		.executableTarget(
			name: "dockctl",
			dependencies: ["DockCore"],
			path: "Sources/dockctl"
		),
		.target(
			name: "VirtualDisplay",
			path: "Sources/VirtualDisplay",
			publicHeadersPath: "include",
			linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
		),
		.executableTarget(
			name: "WD19Split",
			dependencies: ["DockCore", "VirtualDisplay"],
			path: "Sources/WD19Split",
			swiftSettings: [.swiftLanguageMode(.v5)],
			linkerSettings: [
				.linkedFramework("CoreGraphics"), .linkedFramework("IOKit"),
				.linkedFramework("ScreenCaptureKit"), .linkedFramework("QuartzCore"),
				.linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
			]
		),
	]
)
