import Foundation

/// Idempotent first-run installer. Each sidecar ships a `setup.sh` that
/// creates a `uv`-managed virtual environment under
/// `~/Library/Application Support/Rocky/sidecars/<name>/.venv`.
///
/// `runIfNeeded` checks the venv path. If absent or missing the Python
/// binary, it runs `setup.sh` synchronously.
public enum FirstRunSetup {
    public struct Result: Sendable {
        public let didRun: Bool
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    public static func runIfNeeded(
        sidecarDir: URL,
        venvDir: URL,
        scriptName: String = "setup.sh"
    ) throws -> Result {
        let pythonBin = venvDir.appendingPathComponent("bin/python")
        if FileManager.default.fileExists(atPath: pythonBin.path(percentEncoded: false)) {
            return Result(didRun: false, stdout: "", stderr: "", exitCode: 0)
        }

        try FileManager.default.createDirectory(
            at: venvDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let script = sidecarDir.appendingPathComponent(scriptName)
        guard FileManager.default.fileExists(atPath: script.path(percentEncoded: false)) else {
            throw SidecarError.process(message: "setup script missing: \(script.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path(percentEncoded: false)]
        process.currentDirectoryURL = sidecarDir

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        return Result(
            didRun: true,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}
