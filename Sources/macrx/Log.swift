import Foundation

/// Timestamped stderr logging shared by every component.
enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ s: String) {
        let line = "[macrx " + formatter.string(from: Date()) + "] " + s + "\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

func log(_ s: String) { Log.write(s) }
