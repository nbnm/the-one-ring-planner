import Foundation
import AppKit
import Network

// Google Desktop OAuth uses the system browser and a short-lived, loopback-only callback.
public actor GoogleBrowserAuthorizer: GoogleAuthorizing {
    private var flow: GoogleLoopbackFlow?
    private let openBrowser: @Sendable (URL) async -> Bool
    public init(openBrowser: @escaping @Sendable (URL) async -> Bool = { url in await MainActor.run { NSWorkspace.shared.open(url) } }) { self.openBrowser = openBrowser }
    public func authorize(configuration: GoogleOAuthConfiguration, requestedScopes: [String]) async throws -> GoogleAuthorizationCode {
        cancel()
        let verifier = try GoogleOAuth.randomString(), state = try GoogleOAuth.randomString()
        let flow = GoogleLoopbackFlow(state: state); self.flow = flow
        return try await withTaskCancellationHandler {
            defer { if self.flow === flow { self.flow = nil }; flow.cancel() }
            let redirect = try await flow.start()
            guard await openBrowser(GoogleOAuth.authorizationURL(clientID: configuration.clientID, redirect: redirect, state: state, verifier: verifier, requestedScopes: requestedScopes)) else { throw GoogleCalendarError.cancelled }
            let code = try await flow.code()
            try Task.checkCancellation()
            return GoogleAuthorizationCode(code: code, redirect: redirect, verifier: verifier)
        } onCancel: { flow.cancel() }
    }
    public func cancel() { flow?.cancel(); flow = nil }
}

private final class GoogleLoopbackFlow: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.t1a.planner.google-oauth-loopback")
    private let state: String
    // Mutable state is confined to queue, including Network callbacks.
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var reply: CheckedContinuation<String, Error>?
    private var completed: Result<String, Error>?
    private var redirect: URL?
    private var timeout: DispatchWorkItem?
    private var connections: [UUID: NWConnection] = [:]
    init(state: String) { self.state = state }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let completed = self.completed { continuation.resume(throwing: completed.failure ?? GoogleCalendarError.cancelled); return }
                self.ready = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] status in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            guard let port = self.listener?.port, self.completed == nil else { return }
                            let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth2callback")!
                            self.redirect = redirect
                            self.ready?.resume(returning: redirect); self.ready = nil
                        case .failed: self.finish(.failure(GoogleCalendarError.callback))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }; self.accept(connection)
                    }
                    listener.start(queue: self.queue)
                    let timeout = DispatchWorkItem { self.finish(.failure(GoogleCalendarError.timeout)) }
                    self.timeout = timeout; self.queue.asyncAfter(deadline: .now() + 180, execute: timeout)
                } catch { self.finish(.failure(GoogleCalendarError.callback)) }
            }
        }
    }
    func code() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let completed = self.completed { continuation.resume(with: completed) }
                else { self.reply = continuation }
            }
        }
    }
    func cancel() { queue.async { self.finish(.failure(GoogleCalendarError.cancelled)) } }
    private func finish(_ result: Result<String, Error>) {
        guard completed == nil else { return }
        completed = result; timeout?.cancel(); timeout = nil
        ready?.resume(throwing: result.failure ?? GoogleCalendarError.cancelled); ready = nil
        reply?.resume(with: result); reply = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections = [:]
    }
    private func accept(_ connection: NWConnection) {
        guard completed == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { self.connections.removeValue(forKey: id)?.cancel() }
        receive(connection, id: id, buffer: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, closed, error in
            var buffer = buffer; if let data { buffer.append(data) }
            guard error == nil, buffer.count <= 16_384 else { self.connections.removeValue(forKey: id)?.cancel(); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !closed { self.receive(connection, id: id, buffer: buffer) }
                else { self.connections.removeValue(forKey: id)?.cancel() }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let request = lines.first?.split(separator: " ").map(String.init) ?? []
            var result: Result<String, Error>?
            if request.count == 3, request[0] == "GET", request[1].hasPrefix("/oauth2callback?"), let redirect = self.redirect,
               lines.dropFirst().contains(where: { $0.lowercased() == "host: 127.0.0.1:\(redirect.port!)" }),
               let url = URL(string: "http://127.0.0.1:\(redirect.port!)" + request[1]) {
                do { result = .success(try GoogleOAuth.code(from: url, redirect: redirect, state: self.state)) }
                catch GoogleCalendarError.consent { result = .failure(GoogleCalendarError.consent) }
                catch { /* Ignore forged/malformed callbacks; the legitimate flow may still finish. */ }
            }
            let accepted = result != nil
            let body = "<!doctype html><html><head><meta charset=utf-8><title>The One Ring Planner</title></head><body><h1>\(accepted ? "Google sign-in response received" : "Invalid sign-in response")</h1><p>\(accepted ? "Return to The One Ring Planner to finish connecting. You can close this tab." : "Return to the Google sign-in tab and try again.")</p></body></html>"
            let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                self.connections.removeValue(forKey: id)?.cancel()
                if let result { self.finish(result) }
            })
        }
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}
