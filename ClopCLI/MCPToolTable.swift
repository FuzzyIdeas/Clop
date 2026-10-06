//
//  MCPToolTable.swift
//  ClopCLI
//
//  The tools `clop mcp serve` offers, their schemas and their handlers. Descriptions are what the
//  agent reads before it picks one, so they carry the caveats: what a tool changes on disk, what it
//  turns on behind the user's back, and what it needs before it will run at all.
//

import Foundation

// MARK: - Server instructions

extension MCPServer {
    /// Sent once at `initialize`, for the agent's context. The server can only ask about a gap in its
    /// arguments, and by then the agent has already turned "2x" into a number, so an ambiguity in the
    /// user's words has to be caught by the agent, before the call.
    static let instructions = """
    Clop does exactly what a tool's arguments say, so settle ambiguous wording with the user before \
    calling a tool, as choices in your own question UI when you have one. Ask every open question in \
    one go, and skip any the user already answered.

    - "Smaller" is compression (same pixel size, lower quality: compression 5 to 100 on the file \
    tools, optimise(compression: N) in a pipeline), resolution (fewer pixels: a downscale factor, \
    0.5 is half the width and height), or both. Ask which, and how much.
    - "2x", "3x" or "N times" on a video or audio file is playback speed. Clop has no upscaling \
    step, so it never means a larger frame and there is nothing to ask there.
    - A video speed-up either keeps every frame (smoother, the frame rate rises with the speed) or \
    drops frames back to the source rate (smaller file). In a pipeline the answer goes into the \
    step: changeSpeed(factor: 2.0, frames: keep) or frames: drop. On clop_optimise it is \
    playbackSpeedFrames: keep or drop. Left out, it follows the playbackSpeedFrameBehaviour \
    setting, which applies to every video.
    - "Silent" or "mute" is removeAudio, and needs no question.
    - Attaching a pipeline to a folder makes Clop process every matching file that lands there from \
    then on. Say so before attaching one.

    Some tools ask the user themselves, through an elicitation form, when their arguments leave a \
    gap. When that question goes unanswered, the tool returns the options as text: ask in your own \
    chat, then call again with the answer.
    """
}

// MARK: - Elicitation copy

extension MCPServer {
    /// Clop asks the user only for real ambiguity, and there are exactly three cases: "make it smaller"
    /// is compression or resolution or both, a size or compression with no number in it, and a video
    /// speed-up that doesn't say what happens to the frames. A tool that already knows what to do
    /// never stops to ask.
    static let smallerSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "target": [
                "type": "string",
                "title": "Make smaller by",
                "description": "Compression keeps the pixel size, resolution keeps the quality",
                "oneOf": [
                    ["const": "compression", "title": "Compressing it"],
                    ["const": "resolution", "title": "Reducing the resolution"],
                    ["const": "both", "title": "Both"],
                ],
                "default": "compression",
            ],
            // Clop's own scale, the one the compression slider and every other tool use. No default:
            // left empty, Clop's compression setting applies.
            "compression": [
                "type": "integer",
                "title": "Compression",
                "description": "5 is the best quality, 100 the smallest file. Leave empty for Clop's compression setting.",
                "minimum": 5,
                "maximum": 100,
            ],
        ],
        // `compression` stays out of `required` so someone who only picks a target is not blocked on a
        // number they have no opinion about.
        "required": ["target"],
    ]

    static let smallerOptionsText = """
    Clop can make a file smaller in two ways, and the request did not say which.
      compression: keeps the pixel size and lowers the quality. Pass smallerBy=compression, \
    and compression as 5 to 100 (5 is the best quality, 100 the smallest file; left out, Clop's \
    compression setting applies).
      resolution: keeps the quality and shrinks the pixels. Pass smallerBy=resolution, \
    and downscaleFactor as 0 to 1 (0.5 is half the width and height).
      both: compress and downscale in one pass. Pass smallerBy=both.
    Ask the user which they want, then call clop_optimise again with that argument.
    """

    static let factorSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "factor": [
                "type": "number",
                "title": "Downscale to",
                "description": "A fraction of the current size. 0.5 is half the width and height.",
                "minimum": 0.05,
                "maximum": 0.95,
                "default": 0.5,
            ],
        ],
        "required": ["factor"],
    ]

    static let factorOptionsText = """
    Downscaling needs a number and the request did not carry one. The factor is a fraction \
    of the current size: 0.5 is half the width and height, 0.75 is a quarter off, 0.25 is a \
    quarter of the size. For audio the same factor applies to the bitrate.
    Ask the user how much smaller they want it, then call clop_downscale again with factor.
    """

    /// The option labels are the Settings picker's own, so the form and the setting it overrides read
    /// the same. `current` is that setting, so taking the default changes nothing.
    static func framesSchema(current: String) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "frames": [
                    "type": "string",
                    "title": "Frames",
                    "oneOf": [
                        ["const": "keep", "title": "Keep frames (smoother, higher fps)"],
                        ["const": "drop", "title": "Drop frames (smaller file)"],
                    ],
                    "default": current,
                ],
            ],
            "required": ["frames"],
        ]
    }

    /// `pipeline` says where the answer goes: into the DSL step, or into clop_optimise's argument.
    static func framesOptionsText(tool: String, current: String, pipeline: Bool) -> String {
        let (keep, drop) = pipeline
            ? ("Write frames: keep into the changeSpeed step.", "Write frames: drop.")
            : ("Pass playbackSpeedFrames: keep.", "Pass playbackSpeedFrames: drop.")
        return """
        This speeds up video and does not say what happens to the frames. A speed-up leaves more \
        frames per second than the source had, and the request did not say which way to go.
          keep: every frame stays, so motion is smoother and the frame rate rises with the speed \
        (2x of a 30 fps video plays at 60 fps). \(keep)
          drop: frames are dropped back to the source frame rate, so the file is smaller. \(drop)
        Leaving it out follows Clop's playbackSpeedFrameBehaviour setting, which is \(current) now.
        Ask the user which they want, then call \(tool) again with the answer.
        """
    }

    /// A client can answer a question without answering it: declined, cancelled, or dismissed because
    /// it had no way to show it at all. A non-interactive Claude Code session declares the elicitation
    /// capability and then cancels every request, so this is the common path and not the rare one.
    ///
    /// All three end the same way: say what happened in one line, then repeat the full options so the
    /// agent can ask in its own chat and call again. Anything shorter leaves it guessing at parameter
    /// names.
    static let cancelledPrefix = """
    The question was not answered. Some clients cannot show one at all, a non-interactive session \
    for instance, so ask the user directly instead.

    """

    static let declinedPrefix = "The user declined to answer, so ask them directly instead.\n"
}

// MARK: - File operations

// `--async` is never passed: it returns before the work is done and prints no JSON body at all, so a
// result parsed from it would be a lie about what happened.

extension MCPServer {
    static func optimise(_ a: [String: Any]) throws -> ToolOutput {
        let files = try paths(a)
        var smallerBy = a["smallerBy"] as? String
        var compression = a["compression"].map { argument($0) }
        let factor = a["downscaleFactor"]

        // The one genuinely ambiguous request. When the caller already said how, or already gave a
        // number, this asks nothing. A speed change or audio removal says what the call is for, so
        // "speed this up" or "mute this" isn't asked how to make the file smaller.
        if (smallerBy ?? "").isEmpty, compression == nil, factor == nil, a["crop"] == nil,
           a["playbackSpeedFactor"] == nil, a["removeAudio"] as? Bool != true
        {
            try refuseBeforeAsking(files)
            switch try ask("smaller_how", "Clop can make \(subject(files)) smaller in two ways. Which should it use?", smallerSchema) {
            case let .answered(content):
                smallerBy = (content["target"] as? String) ?? "compression"
                compression = asInt(content, "compression", nil).map(String.init)
            case .declined:
                return .text(declinedPrefix + smallerOptionsText)
            case .unanswered:
                return .text(cancelledPrefix + smallerOptionsText)
            case .unsupported:
                return .text(smallerOptionsText)
            }
        }

        var frames = a["playbackSpeedFrames"].map { argument($0) }
        if frames == nil, asDouble(a, "playbackSpeedFactor", 1) > 1, mayContainVideo(files) {
            switch try askFrames(
                message: "When Clop speeds up \(subject(files)), should it keep every frame and make the video smoother or drop frames for smaller size?",
                tool: "clop_optimise",
                pipeline: false,
                files: files
            ) {
            case let .settled(value): frames = value
            case let .askInChat(output): return output
            }
        }

        var argv = ["optimise", "files"] + files + commonFlags(a)
        if let compression {
            argv += ["--compression", compression]
        }
        if smallerBy == "resolution" || smallerBy == "both" {
            argv += ["--downscale-factor", factor.map { argument($0) } ?? "0.5"]
        } else if let factor {
            argv += ["--downscale-factor", argument(factor)]
        }
        argv += opt(a, "--crop", "crop")
            + opt(a, "--pdf-dpi", "pdfDPI")
            + opt(a, "--playback-speed-factor", "playbackSpeedFactor")
            + (frames.map { ["--playback-speed-frames", $0] } ?? [])
            + flag(a, "removeAudio", "--remove-audio")
        return try run(argv, timeout: fileTimeout)
    }

    static func downscale(_ a: [String: Any]) throws -> ToolOutput {
        let files = try paths(a)
        var factor = a["factor"].map { argument($0) }
        if factor == nil {
            try refuseBeforeAsking(files)
            switch try ask("downscale_factor", "How much smaller should Clop make \(subject(files))?", factorSchema) {
            case let .answered(content):
                factor = "\(asDouble(content, "factor", 0.5))"
            case .declined:
                return .text(declinedPrefix + factorOptionsText)
            case .unanswered:
                return .text(cancelledPrefix + factorOptionsText)
            case .unsupported:
                return .text(factorOptionsText)
            }
        }
        return try run(
            ["downscale"] + files + ["--factor", factor ?? "0.5"]
                + commonFlags(a) + flag(a, "removeAudio", "--remove-audio"),
            timeout: fileTimeout
        )
    }

    static func convert(_ a: [String: Any]) throws -> ToolOutput {
        let kind = a["kind"] as? String ?? ""
        guard ["image", "video", "audio"].contains(kind) else {
            throw ClopMCPError("kind must be image, video or audio")
        }
        return try run(
            ["convert", kind, "--to", argument(a["to"] ?? "")] + paths(a)
                + commonFlags(a)
                + opt(a, "--compression", "compression")
                + opt(a, "--bitrate", "bitrate")
                + opt(a, "--convert-behaviour", "convertBehaviour"),
            timeout: fileTimeout
        )
    }

    static func crop(_ a: [String: Any]) throws -> ToolOutput {
        // The crop command spells `-s` as `--size`, so every flag here is written long to keep it from
        // meaning `--skip-errors` the way it does on optimise.
        try run(
            ["crop"] + paths(a) + ["--size", argument(a["size"] ?? "")]
                + commonFlags(a)
                + flag(a, "longEdge", "--long-edge")
                + flag(a, "smartCrop", "--smart-crop")
                + flag(a, "removeAudio", "--remove-audio"),
            timeout: fileTimeout
        )
    }

    static func stripExif(_ a: [String: Any]) throws -> ToolOutput {
        try text(
            ["strip-exif"] + paths(a)
                + flag(a, "recursive", "--recursive")
                + opt(a, "--types", "types"),
            timeout: fileTimeout
        )
    }

    static func cropPDF(_ a: [String: Any]) throws -> ToolOutput {
        guard a["forDevice"] != nil || a["paperSize"] != nil || a["aspectRatio"] != nil else {
            throw ClopMCPError("give one of forDevice, paperSize or aspectRatio")
        }
        do {
            return try cropPDFRun(a)
        } catch let error as ClopMCPError {
            // The CLI answers an unknown name by pointing at a flag, which a person can run and an
            // agent cannot. The agent gets the listing that flag prints, and the pointer is dropped so
            // nothing sends it after a flag it has no way to use.
            guard let (pointer, command) = deviceListing(error.message),
                  case let .text(listing)? = try? text(command, timeout: 10)
            else { throw error }
            throw ClopMCPError(error.message.replacingOccurrences(of: pointer, with: ".") + "\n\n" + listing)
        }
    }

    /// The flag pointer in a bad `--for-device` or `--paper-size` message, and the command that
    /// prints what it points at. Nil for every other error.
    static func deviceListing(_ message: String) -> (pointer: String, command: [String])? {
        for (flag, pointer) in [
            ("--list-devices", ", use --list-devices to see possible values"),
            ("--list-paper-sizes", ", use --list-paper-sizes to see possible values"),
        ] where message.contains(pointer) {
            return (pointer, ["crop-pdf", flag])
        }
        return nil
    }

    private static func cropPDFRun(_ a: [String: Any]) throws -> ToolOutput {
        try text(
            ["crop-pdf"] + paths(a)
                + opt(a, "--for-device", "forDevice")
                + opt(a, "--paper-size", "paperSize")
                + opt(a, "--aspect-ratio", "aspectRatio")
                + opt(a, "--page-layout", "pageLayout")
                + opt(a, "--output", "output")
                + flag(a, "recursive", "--recursive")
                + flag(a, "extend", "--extend"),
            timeout: fileTimeout
        )
    }

    static func uncropPDF(_ a: [String: Any]) throws -> ToolOutput {
        try text(
            ["uncrop-pdf"] + paths(a)
                + flag(a, "recursive", "--recursive")
                + opt(a, "--output", "output"),
            timeout: fileTimeout
        )
    }
}

// MARK: - Pipelines

// Every one of these runs a `clop pipeline` command, which asks Clop's gate before it writes anything.
// Writing the steps from the server would go around the gate entirely: they would land while the
// switch reads "off", and Clop's own watcher would pick them up and run agent-authored steps anyway.
// Clop validates the name and the source path too, since `../../.zshrc` is a name an agent can ask
// for, and it is the app that enforces Pro, mcpEnabled and mcpAllowScriptSteps.

extension MCPServer {
    /// Whether a pipeline for `type` can reach a video. No type means every type.
    static func takesVideo(_ type: Any?) -> Bool {
        ["", "video"].contains(argument(type ?? "").lowercased())
    }

    /// How the questions name where an attached pipeline runs.
    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "clipboard": "the clipboard"
        case "dropZone": "the drop zone"
        default: "“\((source as NSString).lastPathComponent)”"
        }
    }

    static func pipelineRun(_ a: [String: Any]) throws -> ToolOutput {
        let files = try paths(a)
        var pipeline = argument(a["pipeline"] ?? "")
        if mayContainVideo(files) {
            switch try settleSpeedFrames(
                pipeline,
                message: "When Clop speeds up \(subject(files)), should it keep every frame and make the video smoother or drop frames for smaller size?",
                tool: "clop_pipeline_run",
                files: files
            ) {
            case let .settled(settled): pipeline = settled
            case let .askInChat(output): return output
            }
        }
        return try run(
            ["pipeline", "run", pipeline] + files
                + flag(a, "recursive", "--recursive")
                + flag(a, "skipErrors", "--skip-errors")
                + flag(a, "hideResult", "--hide-result")
                + opt(a, "--types", "types")
                + opt(a, "--optimise-behaviour", "optimiseBehaviour")
                + opt(a, "--convert-behaviour", "convertBehaviour")
                + ["--no-progress"],
            timeout: fileTimeout
        )
    }

    static func pipelineWrite(_ a: [String: Any]) throws -> ToolOutput {
        let name = argument(a["name"] ?? "")
        var steps = argument(a["steps"] ?? "")
        if takesVideo(a["fileType"]) {
            switch try settleSpeedFrames(
                steps,
                message: "When “\(name)” speeds up a video, should Clop keep every frame and make the video smoother or drop frames for smaller size?",
                tool: "clop_pipeline_write"
            ) {
            case let .settled(settled): steps = settled
            case let .askInChat(output): return output
            }
        }
        return try text(
            ["pipeline", "add", name, steps]
                + opt(a, "--file-type", "fileType")
                + flag(a, "skipOptimisation", "--skip-optimisation")
                + flag(a, "hideResult", "--hide-result")
                + flag(a, "replace", "--force"),
            timeout: 60
        )
    }

    static func pipelineAttach(_ a: [String: Any]) throws -> ToolOutput {
        var pipeline = argument(a["pipeline"] ?? "")
        let source = argument(a["source"] ?? "")
        if takesVideo(a["type"]) {
            switch try settleSpeedFrames(
                pipeline,
                message: "When the pipeline for \(sourceLabel(source)) speeds up a video, should Clop keep every frame and make the video smoother or drop frames for smaller size?",
                tool: "clop_pipeline_attach"
            ) {
            case let .settled(settled): pipeline = settled
            case let .askInChat(output): return output
            }
        }
        return try text(
            [
                "pipeline",
                "attach",
                pipeline,
                "--source",
                source,
                "--type",
                argument(a["type"] ?? ""),
            ]
                + flag(a, "skipOptimisation", "--skip-optimisation")
                + flag(a, "hideResult", "--hide-result"),
            timeout: 60
        )
    }

    static func pipelineDetach(_ a: [String: Any]) throws -> ToolOutput {
        guard a["index"] == nil || a["all"] as? Bool != true else {
            throw ClopMCPError("pass index or all, not both")
        }
        return try text(
            [
                "pipeline",
                "detach",
                "--source",
                argument(a["source"] ?? ""),
                "--type",
                argument(a["type"] ?? ""),
            ]
                + opt(a, "--index", "index")
                + flag(a, "all", "--all"),
            timeout: 60
        )
    }

    static func pipelinePreset(_ a: [String: Any]) throws -> ToolOutput {
        let action = a["action"] as? String ?? "add"
        if action == "remove" {
            return try text(
                ["pipeline", "preset", "remove", argument(a["name"] ?? "")]
                    + opt(a, "--type", "type"),
                timeout: 60
            )
        }
        var pipeline = argument(a["pipeline"] ?? "")
        guard !pipeline.isEmpty else {
            throw ClopMCPError("adding a preset zone needs a pipeline: a saved name or inline steps")
        }
        let name = argument(a["name"] ?? "")
        if takesVideo(a["type"]) {
            switch try settleSpeedFrames(
                pipeline,
                message: "When the “\(name)” zone speeds up a video, should Clop keep every frame and make the video smoother or drop frames for smaller size?",
                tool: "clop_pipeline_preset"
            ) {
            case let .settled(settled): pipeline = settled
            case let .askInChat(output): return output
            }
        }
        return try text(
            ["pipeline", "preset", "add", name, pipeline]
                + opt(a, "--type", "type")
                + opt(a, "--icon", "icon")
                + flag(a, "skipOptimisation", "--skip-optimisation")
                + flag(a, "hideResult", "--hide-result")
                + flag(a, "replace", "--force"),
            timeout: 60
        )
    }
}

// MARK: - Debug logs

extension MCPServer {
    /// `clop logs persist` gets root from sudo, which needs a terminal, and this process has none: its
    /// stdin and stdout are the JSON-RPC stream. An administrator dialog is the way left, and osascript
    /// gets its own pipes so nothing it prints can land in that stream.
    ///
    /// Never routed through the app or its MCP switch. macOS asks for the password itself, and that
    /// dialog is a stronger gate than either.
    static func debugLogs(_ a: [String: Any]) throws -> ToolOutput {
        guard let action = (a["action"] as? String).flatMap(LogPersistAction.init(rawValue:)) else {
            throw ClopMCPError("action must be on, off or status")
        }
        let command = CLOP_LOG_SUBSYSTEMS
            .map { (["/usr/bin/log"] + action.logConfigArguments(subsystem: $0)).map(shellQuoted).joined(separator: " ") }
            // && so a failure on any subsystem is the one reported, rather than only the last one's.
            .joined(separator: " && ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(appleScriptEscaped(command))\" with prompt \"\(appleScriptEscaped(action.passwordPrompt))\" with administrator privileges"]
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw ClopMCPError("Could not change the log settings: \(error.localizedDescription)")
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let complaint = (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // -128 is AppleScript's userCanceledErr, which is what the dialog's Cancel button raises.
            if complaint.contains("-128") {
                throw ClopMCPError("The user cancelled the administrator password dialog. Nothing changed.")
            }
            throw ClopMCPError("Could not change the log settings: "
                + (complaint.isEmpty ? "osascript exited with status \(process.terminationStatus)" : complaint))
        }
        if let message = action.doneMessage {
            return .text(message)
        }
        // `do shell script` hands back the command's output with carriage returns for line breaks.
        return .text(output.replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The words are fixed today, but this string runs as root, so a subsystem or mode that ever
    /// carries a space or a quote has to stay one argument instead of becoming more shell.
    static func shellQuoted(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: { !shellSafe.contains($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let shellSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:,=@%+"))

    /// For the inside of an AppleScript string literal, where only backslash and double quote are special.
    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - The table

extension MCPServer {
    static let gate = "Refused until the user allows agent changes in Clop Settings, MCP, and the whole MCP "
        + "server needs Clop Pro. Clop's own words come back verbatim when it refuses."

    static let tools: [MCPTool] = [
        // --- the switch
        MCPTool(
            name: "clop_start_server",
            description: "Ask the user to allow changes through MCP, launching Clop if it is not running. "
                + "Clop puts an alert on screen and this waits for the answer, so call it once, in "
                + "response to something the user asked for, and tell them to expect it. Clop refuses "
                + "every mutating tool until they allow it; reading works either way once they have "
                + "Clop Pro, and the choice sticks across launches until it is stopped.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try startServer() }
        ),
        MCPTool(
            name: "clop_stop_server",
            description: "Stop allowing changes through MCP. Reading stays available.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try stopServer() }
        ),
        MCPTool(
            name: "clop_status",
            description: "Clop's version, whether the user has Clop Pro, whether agent changes are allowed, "
                + "whether script steps are allowed, and where the server lives. Read this first when "
                + "a tool has been refused.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try status() }
        ),
        // --- settings
        MCPTool(
            name: "clop_settings_schema",
            description: "Every user-facing Clop setting: its key, current value, type, allowed values, and the "
                + "same title, subtitle and keywords the Settings window shows. Pass a plain-language "
                + "query to narrow it with Clop's own settings search, which is how a question like "
                + "'stop replacing the original' or 'why is the mov not becoming an mp4' finds the "
                + "control that answers it. Call this before clop_settings_set: the value a set takes is "
                + "the string form this shows, and a row with type 'none' hosts no key and can only be "
                + "pointed at.",
            inputSchema: ["type": "object", "properties": [
                "query": ["type": "string", "description": "plain-language filter, e.g. 'replace the original', 'pdf quality'"],
            ]],
            handler: { a in
                let query = (a["query"] as? String) ?? ""
                return try run(["settings", "schema"] + (query.isEmpty ? [] : [query]))
            }
        ),
        MCPTool(
            name: "clop_settings_get",
            description: "Read one setting by its key. Keys come from clop_settings_schema.",
            inputSchema: ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]],
            handler: { a in try run(["settings", "get", argument(a["key"] ?? "")]) }
        ),
        MCPTool(
            name: "clop_settings_set",
            description: "Change one setting. The value is the string form clop_settings_schema shows: true or "
                + "false for a bool, a number, or one of the allowed names for an enum. Applies "
                + "immediately and comes back carrying the new value, so no follow-up read is needed. "
                + gate,
            inputSchema: ["type": "object", "properties": [
                "key": ["type": "string"], "value": ["type": "string"],
            ], "required": ["key", "value"]],
            handler: { a in try run(["settings", "set", argument(a["key"] ?? ""), argument(a["value"] ?? "")]) }
        ),
        // --- files
        MCPTool(
            name: "clop_optimise",
            description: "Optimise images, videos, PDFs and audio in place, or into a copy. Smaller files, same "
                + "pixels, unless a downscale is asked for. When the request is only 'make this smaller' "
                + "and carries no compression, factor or crop, Clop asks the user whether to compress, "
                + "downscale or do both, since those give very different files. Pass smallerBy, compression "
                + "or downscaleFactor to skip that question; a call with playbackSpeedFactor "
                + "or removeAudio is never asked it. Placement follows Clop's own setting, which "
                + "usually rewrites the original, so pass copy when the original must survive. " + gate,
            inputSchema: ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"], "description": "files, folders or URLs"],
                "smallerBy": ["type": "string", "description": "compression, resolution or both"],
                "compression": ["type": "string", "description": "5 to 100, or adaptive, or auto. Above 75, HDR is converted to SDR"],
                "downscaleFactor": ["type": "number", "description": "0 to 1, 0.5 is half the width and height"],
                "crop": ["type": "string", "description": "WxH, e.g. 1920x1080"],
                "pdfDPI": ["type": "string", "description": "adaptive, 300, 250, 200, 150, 100, 72 or 48"],
                "playbackSpeedFactor": [
                    "type": "number",
                    "description": "video only, 2 is twice as fast. A speed-up asks the user whether to keep or drop frames unless playbackSpeedFrames says",
                ],
                "playbackSpeedFrames": [
                    "type": "string",
                    "description": "keep or drop: what a speed-up does with the frames, for this call alone. keep is smoother, the frame rate rising with the speed; drop goes back to the source frame rate for a smaller file. Omitted on a video speed-up, Clop asks the user",
                ],
                "removeAudio": ["type": "boolean", "description": "video only"],
                "aggressive": ["type": "boolean"],
                "copy": ["type": "boolean", "description": "keep the original and write a copy"],
                "recursive": ["type": "boolean", "description": "walk folders"],
                "types": ["type": "string", "description": "comma-separated extensions to include"],
                "output": ["type": "string", "description": "output path or template"],
                "behaviour": ["type": "string", "description": "temp, inplace, samefolder or specificfolder"],
                "skipErrors": ["type": "boolean"],
            ], "required": ["paths"]],
            handler: optimise
        ),
        MCPTool(
            name: "clop_downscale",
            description: "Downscale and optimise images, videos and audio by a factor. For audio the factor "
                + "applies to the bitrate. When no factor is given Clop asks the user for one, since "
                + "'a bit smaller' is not a number. " + gate,
            inputSchema: ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
                "factor": ["type": "number", "description": "0 to 1, 0.5 is half the width and height"],
                "removeAudio": ["type": "boolean"],
                "aggressive": ["type": "boolean"],
                "copy": ["type": "boolean"],
                "recursive": ["type": "boolean"],
                "types": ["type": "string"],
                "output": ["type": "string"],
                "skipErrors": ["type": "boolean"],
            ], "required": ["paths"]],
            handler: downscale
        ),
        MCPTool(
            name: "clop_convert",
            description: "Convert files to another format. Images take webp, avif, heic, jxl, jpeg, png or gif; "
                + "videos take mp4, gif, webm, hevc or av1 (av1 is the MKV video codec, avif is the "
                + "image format); audio takes mp3, aac, m4a, opus, ogg, flac, wav or aiff. Animated GIF "
                + "and animated WebP convert into each other with every frame intact; any other image "
                + "target yields the first frame alone. Where the "
                + "converted file lands follows Clop's convert placement setting unless "
                + "convertBehaviour says otherwise. " + gate,
            inputSchema: ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
                "kind": ["type": "string", "description": "image, video or audio"],
                "to": ["type": "string", "description": "the target format"],
                "compression": ["type": "string", "description": "5 to 100. Above 75, HDR is converted to SDR"],
                "bitrate": ["type": "integer", "description": "audio only, kbps. Beats compression"],
                "convertBehaviour": ["type": "string", "description": "temp, inplace, samefolder or specificfolder"],
                "copy": ["type": "boolean"],
                "recursive": ["type": "boolean"],
                "types": ["type": "string"],
                "output": ["type": "string"],
                "skipErrors": ["type": "boolean"],
            ], "required": ["paths", "kind", "to"]],
            handler: convert
        ),
        MCPTool(
            name: "clop_crop",
            description: "Crop and optimise images, videos and PDFs to a size or an aspect ratio. size takes "
                + "WxH (1920x1080), a ratio (16:9), or a single number with longEdge. smartCrop keeps "
                + "the interesting part of the frame rather than the centre. " + gate,
            inputSchema: ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
                "size": ["type": "string", "description": "WxH, a ratio like 16:9, or a single number with longEdge"],
                "longEdge": ["type": "boolean", "description": "read size as the long edge"],
                "smartCrop": ["type": "boolean"],
                "removeAudio": ["type": "boolean"],
                "aggressive": ["type": "boolean"],
                "copy": ["type": "boolean"],
                "recursive": ["type": "boolean"],
                "types": ["type": "string"],
                "output": ["type": "string"],
                "skipErrors": ["type": "boolean"],
            ], "required": ["paths", "size"]],
            handler: crop
        ),
        MCPTool(
            name: "clop_strip_exif",
            description: "Delete EXIF metadata from images and videos, in place. Location, camera and "
                + "timestamps go with it, so say what it removes before running it over someone's "
                + "library. " + gate,
            inputSchema: ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
                "recursive": ["type": "boolean"],
                "types": ["type": "string"],
            ], "required": ["paths"]],
            handler: stripExif
        ),
        MCPTool(
            name: "clop_crop_pdf",
            description: "Crop PDFs to a device screen, a paper size or an aspect ratio, without optimising "
                + "them. Non-destructive and reversible with clop_uncrop_pdf, since it only moves the "
                + "crop box. Rewrites the file in place unless output says otherwise. " + gate,
            inputSchema: ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
                "forDevice": ["type": "string", "description": "e.g. iPad Air"],
                "paperSize": ["type": "string", "description": "e.g. A4, Letter"],
                "aspectRatio": ["type": "string", "description": "e.g. 1640x2360 or 16:9"],
                "pageLayout": ["type": "string", "description": "portrait, landscape or auto"],
                "extend": ["type": "boolean", "description": "extend the page instead of cutting into it"],
                "recursive": ["type": "boolean"],
                "output": ["type": "string"],
            ], "required": ["paths"]],
            handler: cropPDF
        ),
        MCPTool(
            name: "clop_uncrop_pdf",
            description: "Restore PDFs to their original size by removing the crop box. " + gate,
            inputSchema: ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
                "recursive": ["type": "boolean"],
                "output": ["type": "string"],
            ], "required": ["paths"]],
            handler: uncropPDF
        ),
        // --- pipelines
        MCPTool(
            name: "clop_pipeline_prompt",
            description: "Clop's own reference for writing a pipeline: every step, its parameters, the values "
                + "each one accepts and the caveats. Read this before authoring or editing any "
                + "pipeline, and reach for a script step only when no built-in step can do the job. "
                + "Pass compact for the short version.",
            inputSchema: ["type": "object", "properties": [
                "task": ["type": "string", "description": "what the pipeline should do, appended as the task"],
                "compact": ["type": "boolean", "description": "the short reference instead of the full one"],
            ]],
            handler: { a in
                let task = (a["task"] as? String) ?? ""
                return try text(
                    ["pipeline", "prompt"]
                        + flag(a, "compact", "--compact")
                        + (task.isEmpty ? [] : [task]),
                    timeout: 45
                )
            }
        ),
        MCPTool(
            name: "clop_pipeline_list",
            description: "Saved pipelines and folder automations, with the DSL each one runs. An automation "
                + "carrying only a libraryID is a reference to a saved pipeline, so resolve it against "
                + "the saved list by id rather than reading it as an empty pipeline.",
            inputSchema: ["type": "object", "properties": [
                "all": ["type": "boolean", "description": "also show orphaned automations and broken references"],
            ]],
            handler: { a in try run(["pipeline", "list"] + flag(a, "all", "--all")) }
        ),
        MCPTool(
            name: "clop_pipeline_show",
            description: "The steps of one saved pipeline, by name.",
            inputSchema: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
            handler: { a in try run(["pipeline", "show", argument(a["name"] ?? "")]) }
        ),
        MCPTool(
            name: "clop_pipeline_run",
            description: "Run a pipeline over files: a saved pipeline by name, or inline DSL steps as one "
                + "string. Inline pipelines run exactly the steps written, with no implicit optimise "
                + "pass, so include an optimise step when one is wanted. Read clop_pipeline_prompt "
                + "before writing inline steps, and try a draft on one file before a folder."
                + " A video speed-up whose changeSpeed step has no frames: keep or drop gets a question to the user first. " + gate,
            inputSchema: ["type": "object", "properties": [
                "pipeline": ["type": "string", "description": "a saved pipeline name, or inline DSL steps"],
                "paths": ["type": "array", "items": ["type": "string"]],
                "recursive": ["type": "boolean"],
                "types": ["type": "string"],
                "hideResult": ["type": "boolean", "description": "do not show the floating result"],
                "optimiseBehaviour": ["type": "string"],
                "convertBehaviour": ["type": "string"],
                "skipErrors": ["type": "boolean"],
            ], "required": ["pipeline", "paths"]],
            handler: pipelineRun
        ),
        MCPTool(
            name: "clop_pipeline_write",
            description: "Ask Clop to save a pipeline to the library, so it can be run by name, attached to a "
                + "folder or hung on a drop zone. steps is the DSL string: read clop_pipeline_prompt "
                + "first, and use a built-in step whenever one can do the job, saying which one was "
                + "tried before reaching for a script. A script step is arbitrary code Clop runs and "
                + "sits behind its own switch, separate from the MCP switch, so a pipeline carrying one "
                + "is refused until the user allows script steps and Clop says which step it refused."
                + " A video speed-up whose changeSpeed step has no frames: keep or drop gets a question to the user first. " + gate,
            inputSchema: ["type": "object", "properties": [
                "name": ["type": "string"],
                "steps": ["type": "string", "description": "the pipeline DSL, one string"],
                "fileType": ["type": "string", "description": "image, video, pdf or audio. Omit for any type"],
                "skipOptimisation": ["type": "boolean", "description": "run only the written steps"],
                "hideResult": ["type": "boolean"],
                "replace": ["type": "boolean", "description": "replace a pipeline of the same name"],
            ], "required": ["name", "steps"]],
            handler: pipelineWrite
        ),
        MCPTool(
            name: "clop_pipeline_delete",
            description: "Delete a saved pipeline by name. " + gate,
            inputSchema: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
            handler: { a in try text(["pipeline", "delete", argument(a["name"] ?? "")], timeout: 60) }
        ),
        MCPTool(
            name: "clop_pipeline_attach",
            description: "Bind a pipeline to a source for one file type: the clipboard, the drop zone, or a "
                + "folder path. A folder source also starts watching that folder and switches automatic "
                + "processing on for that type, so every matching file dropped there is processed from "
                + "then on. Say that to the user before attaching one."
                + " A video speed-up whose changeSpeed step has no frames: keep or drop gets a question to the user first. " + gate,
            inputSchema: ["type": "object", "properties": [
                "pipeline": ["type": "string", "description": "a saved pipeline name or id, or inline DSL steps"],
                "source": ["type": "string", "description": "clipboard, dropZone, or an absolute folder path"],
                "type": ["type": "string", "description": "image, video, pdf or audio"],
                "skipOptimisation": ["type": "boolean"],
                "hideResult": ["type": "boolean"],
            ], "required": ["pipeline", "source", "type"]],
            handler: pipelineAttach
        ),
        MCPTool(
            name: "clop_pipeline_detach",
            description: "Remove one attached pipeline, by its 0-based index, or all of them for that source "
                + "and type. clop_pipeline_list shows what is attached where. " + gate,
            inputSchema: ["type": "object", "properties": [
                "source": ["type": "string", "description": "clipboard, dropZone, or an absolute folder path"],
                "type": ["type": "string", "description": "image, video, pdf or audio"],
                "index": ["type": "integer", "description": "0-based, from clop_pipeline_list"],
                "all": ["type": "boolean"],
            ], "required": ["source", "type"]],
            handler: pipelineDetach
        ),
        MCPTool(
            name: "clop_pipeline_preset",
            description: "Add or remove a preset zone on the drop zone: a named target the user drops files on "
                + "to run one pipeline. Omit type for a zone that takes every file type."
                + " A video speed-up whose changeSpeed step has no frames: keep or drop gets a question to the user first. " + gate,
            inputSchema: ["type": "object", "properties": [
                "action": ["type": "string", "description": "add or remove. Default add"],
                "name": ["type": "string", "description": "the zone's label"],
                "pipeline": ["type": "string", "description": "a saved pipeline name or id, or inline DSL steps"],
                "type": ["type": "string", "description": "image, video, pdf or audio. Omit for all types"],
                "icon": ["type": "string", "description": "SF Symbol name, default wand.and.stars"],
                "skipOptimisation": ["type": "boolean"],
                "hideResult": ["type": "boolean"],
                "replace": ["type": "boolean"],
            ], "required": ["name"]],
            handler: pipelinePreset
        ),
        // --- diagnostics
        MCPTool(
            name: "clop_debug_logs",
            description: "Turns keeping Clop's debug and info log messages on disk on or off, or reports it, so "
                + "`log show --debug` can read what happened before anyone started streaming. Use it when "
                + "reproducing a problem needs logs from earlier. macOS requires root for this: the call "
                + "shows an administrator password dialog on the user's screen and waits, and nothing "
                + "changes if they cancel. Debug builds already keep debug logs.",
            inputSchema: ["type": "object", "properties": [
                "action": [
                    "type": "string",
                    "enum": LogPersistAction.allCases.map(\.rawValue),
                    "description": "on, off or status",
                ],
            ], "required": ["action"]],
            handler: debugLogs
        ),
    ]

    static let toolsByName: [String: MCPTool] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
}
