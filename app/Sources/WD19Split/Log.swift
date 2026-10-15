import Foundation

/// Append-only step log at ~/Library/Logs/WD19Split.log (also to the unified
/// log), so display-setup problems can be diagnosed after the fact.
enum Log {
	static let url = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent("Library/Logs/WD19Split.log")
	private static let queue = DispatchQueue(label: "wd19split.log")
	private static let stamp: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		return f
	}()

	static func write(_ message: String) {
		let line = "\(stamp.string(from: Date())) \(message)\n"
		NSLog("WD19Split: %@", message)
		queue.async {
			guard let data = line.data(using: .utf8) else { return }
			if let h = try? FileHandle(forWritingTo: url) {
				h.seekToEndOfFile()
				h.write(data)
				try? h.close()
			} else {
				try? data.write(to: url)
			}
		}
	}
}
