//
//  LabelingLive.swift
//  Labeler (also compiled into RallyLab)
//
//  Live sync: a Supabase Realtime connection to the private "labeling"
//  topic, where the database announces every save to the labeling tables
//  (migration 045: the table and who saved, no row data). When someone else
//  saves, `onChange` runs — the phone pulls, the Mac syncs — instead of
//  waiting for the next 30-second look. Reconnects by itself (after a drop,
//  offline, or the phone coming back from the background), backing off up
//  to a minute.
//

import Foundation

@MainActor
final class LabelingLive {
    private let onChange: () async -> Void
    private var task: Task<Void, Never>?
    /// A change came in while `onChange` was running: run it again after.
    private var again = false
    private var running = false

    init(onChange: @escaping () async -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var wait = 1.0
        while !Task.isCancelled {
            if (try? await listen()) == true { wait = 1 }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 60)
        }
    }

    /// One connection, until it drops. True if it got as far as joining.
    private func listen() async throws -> Bool {
        let client = LabelingClient.shared
        let token = try await client.liveToken()
        let me = await client.userId?.uuidString.lowercased()
        var url = URLComponents(url: URL(string: Secrets.supabaseURL)!.appending(path: "realtime/v1/websocket"), resolvingAgainstBaseURL: false)!
        url.scheme = "wss"
        url.queryItems = [.init(name: "apikey", value: Secrets.supabaseAnonKey), .init(name: "vsn", value: "1.0.0")]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        try await send(socket, topic: Self.topic, event: "phx_join", ref: "1", payload: [
            "config": ["broadcast": ["self": false, "ack": false], "presence": ["key": ""], "postgres_changes": [], "private": true],
            "access_token": token,
        ])
        // Heartbeats keep the connection; a fresh token before the old one runs out.
        let beat = Task {
            var ref = 2, beats = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                ref += 1
                beats += 1
                try? await send(socket, topic: "phoenix", event: "heartbeat", ref: "\(ref)", payload: [:])
                if beats % 96 == 0, let fresh = try? await client.liveToken() {   // every 40 minutes
                    try? await send(socket, topic: Self.topic, event: "access_token", ref: "\(ref)", payload: ["access_token": fresh])
                }
            }
        }
        defer { beat.cancel() }

        var joined = false
        while !Task.isCancelled {
            guard case .string(let text) = try await socket.receive(),
                  let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let event = message["event"] as? String else { continue }
            let payload = message["payload"] as? [String: Any]
            switch event {
            case "phx_reply" where message["topic"] as? String == Self.topic:
                guard payload?["status"] as? String == "ok" else { return joined }
                if !joined {
                    joined = true
                    changed()   // whatever was missed while not connected
                }
            case "broadcast":
                let notice = (payload?["payload"] as? [String: Any])
                if (notice?["by"] as? String)?.lowercased() != me { changed() }
            case "phx_error", "phx_close", "system" where (payload?["status"] as? String) == "error":
                return joined
            default:
                break
            }
        }
        return joined
    }

    /// Run `onChange`, once at a time; changes while it runs make one more run.
    private func changed() {
        guard !running else { again = true; return }
        running = true
        Task {
            repeat {
                again = false
                await onChange()
            } while again
            running = false
        }
    }

    private static let topic = "realtime:labeling"

    private func send(_ socket: URLSessionWebSocketTask, topic: String, event: String, ref: String, payload: [String: Any]) async throws {
        let message: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": ref, "join_ref": "1"]
        try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)))
    }
}
