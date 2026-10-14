import Foundation
import TailcatCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: String = #filePath, line: Int = #line) throws {
    guard lhs == rhs else { throw CheckFailure(description: "\(URL(fileURLWithPath: file).lastPathComponent):\(line): values differ") }
}
func expectTrue(_ value: Bool, file: String = #filePath, line: Int = #line) throws { try expectEqual(value, true, file: file, line: line) }
func expectFalse(_ value: Bool, file: String = #filePath, line: Int = #line) throws { try expectEqual(value, false, file: file, line: line) }
func expectNil<T>(_ value: T?, file: String = #filePath, line: Int = #line) throws { try expectTrue(value == nil, file: file, line: line) }
func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: String = #filePath, line: Int = #line) throws {
    do { _ = try expression() } catch { return }
    throw CheckFailure(description: "\(URL(fileURLWithPath: file).lastPathComponent):\(line): expected an error")
}

@main struct CheckMain {
    @MainActor static func main() async {
        let session = SessionTests(), persistence = PersistenceTests(), process = ProcessTests()
        let integration = ExternalAndInstallerTests()
        let reachability = ReachabilityTests()
        var checks: [(String, @MainActor () async throws -> Void)] = [
            ("credential authorization cache / silent observation / update", { try reachability.testCredentialsReuseAuthorizationAndUpdateCache() }),
            ("batch ping / bounded concurrency / latency / redaction / no ADB", { try await reachability.testAllDevicesBoundedResultsAndNoADBCommands() }),
            ("batch cancellation / queue cleanup / restart", { try await reachability.testCancellationStopsActiveTestsAndQueueBeforeRestart() }),
            ("concurrent sessions / selective disconnect", { try await session.testConcurrentSessionsAndStoppingOnePreservesOther() }),
            ("fixed task target", { try await session.testTasksBindTargetEvenWhenAnotherDeviceConnects() }),
            ("unauthorized transport remains available", { try await session.testUnauthorizedKeepsTunnelAndRejectsDeviceOperations() }),
            ("cancel connection startup", { try await session.testDisconnectCancelsPendingConnectWithoutLeakingTunnel() }),
            ("reconnect cancels stale task", { try await session.testReconnectCancelsOldTasksBeforeReplacingSession() }),
            ("unexpected process exit isolation", { try await session.testUnexpectedTransportExitDoesNotAffectOtherDevice() }),
            ("repeated import preserves GUI edits / credentials", { try await session.testRepeatedImportPreservesGUIEditsAndCredentials() }),
            ("temporary sessions / memory-only credentials / isolated close", { try await session.testTemporaryDevicesAreMemoryOnlyAndCloseIndependently() }),
            ("promote temporary / preserve connection and active task", { try await session.testPromotionKeepsConnectionAndRunningTask() }),
            ("failed promotion rollback / cancel temporary startup", { try await session.testFailedPromotionRollsBackAndTemporaryStartupCancels() }),
            ("read-only legacy import / unsafe entry rejection", { try persistence.testLegacyImportSkipsSymlinksAndInvalidEntriesWithoutChangingSource() }),
            ("private config / credentials excluded", { try persistence.testConfigurationHasNoCredentialsAndUsesPrivatePermissions() }),
            ("redaction / native listener readiness", { try persistence.testRedactionAndNativeReadinessParsing() }),
            ("stdout and stderr drained / final output", { try await process.testBothPipesDrainAndTrailingOutputIsPreserved() }),
            ("timeout / cancellation terminate process", { try await process.testTimeoutAndCancellationStopOwnedProcess() }),
            ("literal command arguments", { try await process.testArgumentsWithSpacesAreNotEvaluatedByShell() }),
            ("CLI PID / listener / credential match / multiple ports", { try await integration.testScannerValidatesOwnershipAndKeepsMultiplePorts() }),
            ("legacy CLI PID / symlink rejection / no migration", { try await integration.testLegacyPIDAndSymlinkRootAreReadOnly() }),
            ("CLI observation / owned cleanup / external isolation", { try await integration.testExternalDisconnectAndShutdownNeverTouchCLI() }),
            ("CLI operations / metadata / fixed ADB and scrcpy target", { try await integration.testExternalOperationsAndMetadataBindToCLIEntry() }),
            ("CLI replaced PID / unauthorized / offline rejection", { try await integration.testExternalPIDReplacementAndUnauthorizedBlockOperations() }),
            ("GUI exit cancels CLI tasks / preserves external bridge", { try await integration.testShutdownCancelsGUICreatedCLITaskWithoutDisconnect() }),
            ("Homebrew batch / argv / no upgrade / existing discovery", { try await integration.testInstallerBatchUsesExactCommandsAndConfiguresPaths() }),
            ("Homebrew failure / missing brew / cancellation", { try await integration.testInstallerFailureMissingBrewAndCancellation() }),
            ("installed path persists / external connection preserved", { try await integration.testInstalledComponentPersistsWhileCLIStaysOnline() })
        ]
        if CommandLine.arguments.contains("--native-tailcat") {
            checks.append(("installed Tailcat / two listeners / selective cleanup", { try await process.testNativeTailcatListeners() }))
            checks.append(("installed Tailcat / fresh identity per process", { try await process.testNativeEphemeralIdentitiesDifferBetweenProcesses() }))
        }
        if CommandLine.arguments.contains("--keychain") {
            checks.append(("isolated Keychain create / read / update / delete", { try persistence.testIsolatedKeychainRoundTrip() }))
        }
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(Credentials.redact(error.localizedDescription))") }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(1) }
    }
}
