import Foundation

public enum APKInstallStage: String {
    case preparing, uploading, installing, completed
    public var label: String {
        switch self {
        case .preparing: return "准备安装 APK"
        case .uploading: return "正在上传 APK"
        case .installing: return "正在安装 APK，等待车机返回结果"
        case .completed: return "安装完成"
        }
    }
}

public struct APKInstallProgress: Equatable {
    public var stage: APKInstallStage = .preparing
    public var fraction: Double?
    public let totalBytes: Int64
    public init(totalBytes: Int64) { self.totalBytes = totalBytes }
}

/// ADB rewrites its progress line with carriage returns and may split it across reads.
/// Only native transfer percentages are determinate; package installation has no percentage.
public final class APKInstallOutputParser {
    public private(set) var progress: APKInstallProgress
    private var pending = ""
    public init(totalBytes: Int64) { progress = APKInstallProgress(totalBytes: totalBytes) }

    public func append(_ chunk: String) -> APKInstallProgress {
        pending += chunk
        while let boundary = pending.rangeOfCharacter(from: .newlines) {
            consume(String(pending[..<boundary.lowerBound]))
            pending = String(pending[boundary.upperBound...])
        }
        // Terminal progress is often printed *after* a carriage return, with no trailing newline.
        consume(pending)
        if pending.count > 32768 { pending = "" }
        return progress
    }

    public static func plainText(_ output: String) -> String {
        output.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func consume(_ raw: String) {
        let line = Self.plainText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.range(of: "^.+: [0-9]+ files? pushed, [0-9]+ skipped\\.", options: .regularExpression) != nil {
            progress.stage = .installing; progress.fraction = nil
            return
        }
        guard progress.stage != .installing, progress.stage != .completed else { return }
        if line.hasPrefix("Performing Push Install") { progress.stage = .uploading }
        let pattern = "^\\[\\s*([0-9]{1,3})%\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line),
              let percent = Int(line[range]), (0...100).contains(percent) else { return }
        progress.stage = .uploading
        progress.fraction = max(progress.fraction ?? 0, Double(percent) / 100)
    }
}
