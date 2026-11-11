import Combine
import Foundation

/// Token usage for one open Claude Code session.
struct SessionUsage: Identifiable {
    let id: String              // session id
    let name: String            // session name, falling back to the project folder
    let project: String
    let status: String          // "busy", "idle", …
    let messageCount: Int       // assistant messages
    let totalTokens: Int        // input + output + cache writes (cache reads excluded)
    let lastOutputTokens: Int   // output tokens of the most recent message
    let lastContextTokens: Int  // everything the most recent message read (input + cache)
    let model: String?
    let lastPrompt: String?     // the last thing the user typed
    let startedAt: Date
    let updatedAt: Date

    var isBusy: Bool { status == "busy" }

    /// Assumed context window. Transcripts don't record it, so: 1M for the 5.x
    /// models (which sessions here have been seen to fill past 200k), else 200k —
    /// and never smaller than what the session has already used.
    var contextWindow: Int {
        let assumed = (model ?? "").contains("-5-") ? 1_000_000 : 200_000
        return lastContextTokens > assumed ? 1_000_000 : assumed
    }

    var contextFraction: Double {
        min(max(Double(lastContextTokens) / Double(contextWindow), 0), 1)
    }
}

/// Discovers open Claude Code sessions from `~/.claude/sessions/*.json` and sums
/// per-message token usage from their transcripts in `~/.claude/projects/`.
@MainActor
final class SessionUsageMonitor: ObservableObject {
    @Published private(set) var sessions: [SessionUsage] = []

    private let scanner = SessionScanner()
    private var isScanning = false

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let scanner = scanner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scanner.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sessions = result
                    self?.isScanning = false
                }
            }
        }
    }
}

/// Reads session files off the main thread. Transcripts are parsed incrementally
/// (only bytes appended since the last scan) and cached per session.
private final class SessionScanner: @unchecked Sendable {
    private struct Tally {
        var offset: UInt64 = 0
        var seen = Set<String>()
        var total = 0
        var count = 0
        var lastOutput = 0
        var lastContext = 0
        var model: String?
        var lastPrompt: String?
    }

    private let lock = NSLock()
    private var tallies: [String: Tally] = [:]   // keyed by transcript path

    private let home = FileManager.default.homeDirectoryForCurrentUser

    func scan() -> [SessionUsage] {
        lock.lock(); defer { lock.unlock() }

        let sessionsDir = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil)) ?? []

        var result: [SessionUsage] = []
        var livePaths = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sessionId = obj["sessionId"] as? String,
                let cwd = obj["cwd"] as? String
            else { continue }

            // Skip stale registry entries whose process has exited.
            if let pid = (obj["pid"] as? NSNumber)?.int32Value, kill(pid, 0) != 0, errno == ESRCH {
                continue
            }

            let project = (cwd as NSString).lastPathComponent
            let name = (obj["name"] as? String) ?? project
            let status = (obj["status"] as? String) ?? "idle"
            let updatedMs = (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            let startedMs = (obj["startedAt"] as? NSNumber)?.doubleValue ?? updatedMs

            let transcript = transcriptURL(cwd: cwd, sessionId: sessionId)
            livePaths.insert(transcript.path)
            let tally = update(transcript: transcript)
            result.append(SessionUsage(
                id: sessionId,
                name: name,
                project: project,
                status: status,
                messageCount: tally.count,
                totalTokens: tally.total,
                lastOutputTokens: tally.lastOutput,
                lastContextTokens: tally.lastContext,
                model: tally.model,
                lastPrompt: tally.lastPrompt,
                startedAt: Date(timeIntervalSince1970: startedMs / 1000),
                updatedAt: Date(timeIntervalSince1970: updatedMs / 1000)
            ))
        }

        // Drop caches for sessions that are no longer open.
        tallies = tallies.filter { livePaths.contains($0.key) }

        // Stable order (oldest first) so cycling doesn't jump around as sessions update.
        return result.sorted { $0.startedAt < $1.startedAt }
    }

    // Claude Code stores transcripts under a folder named after the cwd with
    // every non-alphanumeric character replaced by "-".
    private func transcriptURL(cwd: String, sessionId: String) -> URL {
        let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return home.appendingPathComponent(".claude/projects/\(folder)/\(sessionId).jsonl")
    }

    private func update(transcript url: URL) -> Tally {
        var tally = tallies[url.path] ?? Tally()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return tally }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < tally.offset { tally = Tally() }          // file was rewritten
        guard size > tally.offset else { tallies[url.path] = tally; return tally }

        try? handle.seek(toOffset: tally.offset)
        let data = (try? handle.readToEnd()) ?? Data()

        // Only consume complete lines; leave a trailing partial line for next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return tally }
        let complete = data[data.startIndex...lastNewline]
        tally.offset += UInt64(complete.count)

        let usageKey = Data("\"usage\"".utf8), userKey = Data("\"type\":\"user\"".utf8)
        for line in complete.split(separator: 0x0A) where line.count > 2 {
            // Cheap pre-filter before paying for JSON parsing.
            guard line.range(of: usageKey) != nil || line.range(of: userKey) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = obj["message"] as? [String: Any]
            else { continue }

            let type = obj["type"] as? String
            if type == "user" {
                if obj["isSidechain"] as? Bool != true, let prompt = Self.typedPrompt(message) {
                    tally.lastPrompt = prompt
                }
                continue
            }

            guard type == "assistant",
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            // One API message can be written as several lines; count it once.
            if let id = message["id"] as? String, !tally.seen.insert(id).inserted { continue }

            func n(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            let input = n("input_tokens"), output = n("output_tokens")
            let write = n("cache_creation_input_tokens"), read = n("cache_read_input_tokens")

            tally.count += 1
            tally.total += input + output + write
            tally.lastOutput = output
            tally.lastContext = input + write + read
            if let model = message["model"] as? String, model != "<synthetic>" { tally.model = model }
        }

        tallies[url.path] = tally
        return tally
    }

    /// The text a user typed (not tool results, system reminders or command wrappers).
    private static func typedPrompt(_ message: [String: Any]) -> String? {
        var text: String?
        if let str = message["content"] as? String {
            text = str
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("[Request interrupted")
        else { return nil }
        t = t.replacingOccurrences(of: "\n", with: " ")
        return t.count > 160 ? String(t.prefix(160)) + "\u{2026}" : t
    }
}
