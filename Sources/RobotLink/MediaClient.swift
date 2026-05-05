import Foundation
import Telemetry

/// Audio upload + playback through the daemon's media endpoints.
///
/// `/api/media/sounds/upload`  multipart, single field "file"
/// `/api/media/play_sound`     {"file": "<filename>"}
/// `/api/media/stop_sound`     no body
public actor MediaClient {
    public let endpoint: RobotEndpoint
    private let session: URLSession
    private let logBus: LogBus

    public init(
        endpoint: RobotEndpoint = RobotEndpoint(),
        session: URLSession = .shared,
        logBus: LogBus
    ) {
        self.endpoint = endpoint
        self.session = session
        self.logBus = logBus
    }

    /// Upload a WAV (or other) file under `filename`. Returns the daemon's
    /// `path` reply (the absolute path it stored the file at).
    @discardableResult
    public func uploadSound(filename: String, data: Data) async throws -> String {
        let url = endpoint.apiURL("/api/media/sounds/upload")
        let boundary = "rocky-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                    .data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let started = Date()
        let (resp, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let ms = Date().timeIntervalSince(started) * 1000
        await logBus.publish(.robotLink(
            endpoint: "/api/media/sounds/upload",
            status: status, latencyMs: ms
        ))
        if !(200..<300).contains(status) {
            let s = String(data: resp, encoding: .utf8) ?? "<binary>"
            throw RobotLinkError.http(status: status, body: s)
        }
        if let json = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
           let path = json["path"] as? String {
            return path
        }
        return filename
    }

    /// `POST /api/media/play_sound` — non-blocking; returns when the daemon
    /// acks (which is the moment playback begins, not when it ends).
    public func playSound(file: String) async throws {
        let url = endpoint.apiURL("/api/media/play_sound")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let file: String }
        req.httpBody = try JSONEncoder().encode(Body(file: file))

        let started = Date()
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let ms = Date().timeIntervalSince(started) * 1000
        await logBus.publish(.robotLink(
            endpoint: "/api/media/play_sound",
            status: status, latencyMs: ms
        ))
        if !(200..<300).contains(status) {
            let s = String(data: data, encoding: .utf8) ?? "<binary>"
            throw RobotLinkError.http(status: status, body: s)
        }
    }

    /// `POST /api/media/stop_sound`
    public func stopSound() async throws {
        let url = endpoint.apiURL("/api/media/stop_sound")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let s = String(data: data, encoding: .utf8) ?? "<binary>"
            throw RobotLinkError.http(status: status, body: s)
        }
    }
}
