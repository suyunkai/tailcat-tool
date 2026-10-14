import Foundation
import TailcatCore

final class APKInstallProgressTests {
    func testSplitTerminalProgressAndInstallationPhase() throws {
        let parser = APKInstallOutputParser(totalBytes: 1024)
        try expectEqual(parser.append("Performing Push Install\r\n").stage, .uploading)
        try expectNil(parser.progress.fraction)
        _ = parser.append("\r\u{001B}[0K[ 4")
        try expectNil(parser.progress.fraction)
        try expectEqual(parser.append("2%] /data/local/tmp/file pushed.apk: 42%").fraction, 0.42)
        try expectEqual(parser.progress.stage, .uploading)
        _ = parser.append("\r[ 1%] ignored backwards update\r[101%] invalid\rnoise 99%\n")
        try expectEqual(parser.progress.fraction, 0.42)
        try expectEqual(parser.append("\r[100%] example.apk: 100%").stage, .uploading)
        try expectEqual(parser.progress.fraction, 1)
        _ = parser.append("\r/example.apk: 1 file pushed, 0 skipped. 2 MB/s\r\n")
        try expectEqual(parser.progress.stage, .installing)
        try expectNil(parser.progress.fraction)
        _ = parser.append("\r[ 80%] late update\r\nSuccess\r\n")
        try expectEqual(parser.progress.stage, .installing)
        try expectNil(parser.progress.fraction)
        try expectEqual(APKInstallOutputParser.plainText("\u{001B}[2K\r[ 42%]"), "\n[ 42%]")
    }
}
