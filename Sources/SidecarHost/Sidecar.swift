import Foundation
import Telemetry

/// Public protocol every sidecar adapter conforms to. The runtime implementation
/// (`SidecarRuntime`) is one conformer; tests can supply fakes.
public protocol Sidecar: AnyObject, Sendable {
    var name: String { get }
    var manifest: SidecarManifest { get }
    var state: SidecarState { get async }
    var events: AsyncStream<SidecarOutboundEvent> { get }

    /// Subscribe synchronously on the actor. Unlike the `events`
    /// getter, this call inserts the continuation into the broadcast
    /// table BEFORE it returns — events emitted between subscribe
    /// and the consumer's first iteration are not lost. Prefer this
    /// for callsites that need exact ordering of `.event` / `.log`
    /// events; `events` is fine for state-mirror consumers because
    /// state is replayed on subscription either way.
    func subscribe() async -> AsyncStream<SidecarOutboundEvent>

    func start() async throws
    func stop() async

    /// Issue a request expecting a single result.
    func send<R: Decodable & Sendable>(method: String, params: any Encodable & Sendable) async throws -> R

    /// Issue a request expecting a stream of items terminated by `stream_end`.
    func stream(method: String, params: any Encodable & Sendable) -> AsyncThrowingStream<Data, Error>
}

/// Events surfaced from a sidecar (unsolicited push, not in response to a request).
public enum SidecarOutboundEvent: Sendable {
    case state(SidecarState)
    case event(name: String, payload: Data)
    case log(level: TelemetryEvent.LogLevel, message: String, fields: [String: String])
}
