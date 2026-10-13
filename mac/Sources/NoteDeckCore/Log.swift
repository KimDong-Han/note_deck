import Foundation

public enum Log {
    public static let fileURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return logs.appendingPathComponent("NoteDeck.log")
    }()
    private static let queue = DispatchQueue(label: "notedeck.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()
    public static var echoToStdout = true

    public static func info(_ msg: String) { write("INFO", msg) }
    public static func warn(_ msg: String) { write("WARN", msg) }
    public static func error(_ msg: String) { write("ERR ", msg) }

    private static func write(_ level: String, _ msg: String) {
        let line = "\(fmt.string(from: Date())) \(level) \(msg)\n"
        if echoToStdout { FileHandle.standardError.write(line.data(using: .utf8)!) }
        queue.async {
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
