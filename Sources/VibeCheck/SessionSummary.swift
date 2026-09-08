import Foundation

/// Builds the human-readable lines about a session, so the click panel and
/// the menu always say the same thing about the same session.
///
/// Everything here reads the transcript that `ProcessMonitor` already
/// resolved and hung on the session, so no caller searches the disk.
///
/// Results are cached per (file, mtime). Building the menu reads the tail of
/// every live session's transcript synchronously on the main thread, which
/// measured 173 ms across five sessions — a visible hitch every time the menu
/// opened. Transcripts are append-only, so an unchanged mtime means the answer
/// is unchanged, and only sessions that actually wrote something since the last
/// look cost anything.
@MainActor
enum SessionSummary {
    private struct CacheKey: Hashable {
        let path: String
        let mtime: Date
        let needsAttention: Bool
    }
    private static var cache: [CacheKey: [String]] = [:]

    static func stateText(_ session: SessionStatus) -> String {
        if session.needsAttention {
            return L10n.t("🧱 waiting for you", "🧱 입력을 기다리는 중")
        }
        switch session.state {
        case .working:
            return L10n.t("running (CPU \(Int(session.cpu))%)",
                          "달리는 중 (CPU \(Int(session.cpu))%)")
        default:
            return L10n.t("idle", "대기 중")
        }
    }

    /// The lines describing what the session is doing right now, in the order
    /// they should be shown: what it is waiting on, its latest answer, and the
    /// instruction it was given.
    static func detailLines(_ session: SessionStatus) -> [String] {
        guard let reader = session.transcript, let file = session.logFile else { return [] }
        let key = CacheKey(
            path: file.path, mtime: Transcripts.modified(file),
            needsAttention: session.needsAttention)
        if let cached = cache[key] { return cached }

        let lines = buildDetailLines(session, reader: reader, file: file)
        // Only the newest state of each transcript is worth keeping.
        cache = cache.filter { $0.key.path != key.path }
        cache[key] = lines
        return lines
    }

    private static func buildDetailLines(
        _ session: SessionStatus, reader: any TranscriptReader.Type, file: URL
    ) -> [String] {
        let detail = reader.detail(in: file)
        var lines: [String] = []

        if session.needsAttention {
            if let question = detail?.pendingQuestion {
                lines.append(L10n.t("❓ Question: \(question)", "❓ 질문: \(question)"))
            } else if let tool = detail?.pendingTool {
                lines.append(L10n.t("🛠️ Waiting to run: \(tool)", "🛠️ 허가 대기: \(tool)"))
            } else if let message = session.attentionMessage {
                lines.append("❓ \(message)")
            } else {
                lines.append(L10n.t("❓ Waiting for input — check the terminal",
                                    "❓ 입력 대기 — 터미널에서 확인하세요"))
            }
        } else if let response = detail?.lastResponse {
            lines.append(L10n.t("🗨️ \(response)", "🗨️ \(response)"))
        }

        if let prompt = detail?.lastPrompt {
            lines.append("💬 \(prompt)")
        }
        return lines
    }

    /// The black bubble shown when a runner is clicked.
    static func panelText(for session: SessionStatus, animal: String) -> String {
        var text = "\(animal) \(L10n.animalName(animal)) · \(session.assistant.displayName)"
        text += "\n📁 \(session.projectName ?? "?") — \(stateText(session))"
        let lines = detailLines(session)
        if lines.isEmpty {
            text += "\n" + L10n.t("💬 no recent instruction found",
                                  "💬 최근 지시를 찾지 못함")
        } else {
            text += "\n" + lines.joined(separator: "\n")
        }
        return text
    }

    /// One row per session in the menu.
    static func menuLine(_ session: SessionStatus, animal: String) -> String {
        let name = session.projectName ?? "PID \(session.pid)"
        if session.needsAttention {
            return "🧱\(animal) \(name) — "
                + L10n.t("waiting for you", "입력을 기다리는 중")
        }
        return "\(animal) \(name) — \(stateText(session))"
    }
}
