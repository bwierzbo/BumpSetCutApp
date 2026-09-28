//
//  ToolEnvironment.swift
//  RallyLab
//
//  RallyLab runs command-line tools (python3, yt-dlp, ffmpeg, yolo). A Mac
//  app starts with a bare PATH, so the usual install locations are added.
//

import Foundation

enum ToolEnvironment {
    static var variables: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin",
                     "/Library/Frameworks/Python.framework/Versions/Current/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return env
    }

    /// Run a tool to completion, collecting its combined output. Off the
    /// main thread; returns the exit status and the output's lines.
    static func run(_ tool: String, _ args: [String], in directory: URL? = nil) async -> (status: Int32, lines: [String]) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [tool] + args
            process.environment = variables
            if let directory { process.currentDirectoryURL = directory }
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            do { try process.run() } catch { return (-1, [error.localizedDescription]) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map(String.init)
            return (process.terminationStatus, lines)
        }.value
    }
}
