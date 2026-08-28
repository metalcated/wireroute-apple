// SPDX-License-Identifier: MIT

import Foundation

public enum RouterOSClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case insecureTransport
    case invalidUsername
    case invalidResponse
    case httpStatus(code: Int, message: String?, detail: String?)
    case invalidPayload
    case writeOutcomeUncertain

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a RouterOS URL containing only the HTTPS router address or its /rest path."
        case .insecureTransport:
            return "RouterOS connections must use HTTPS."
        case .invalidUsername:
            return "The RouterOS username is empty or contains an unsupported colon."
        case .invalidResponse:
            return "RouterOS returned a response that could not be verified."
        case .httpStatus(let code, let message, let detail):
            return ["RouterOS request failed (HTTP \(code)).", message, detail]
                .compactMap { $0 }
                .joined(separator: " ")
        case .invalidPayload:
            return "RouterOS returned data in an unexpected format."
        case .writeOutcomeUncertain:
            return "WireRoute could not confirm whether RouterOS added the peer. Reconnect and inspect the peer list before trying again."
        }
    }
}

public protocol RouterOSHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionRouterOSHTTPTransport: RouterOSHTTPTransport {
    private let session: URLSession
    private let trustDelegate: RouterOSTrustDelegate?

    public init(trustedCertificate: RouterOSServerCertificate? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let trustDelegate = RouterOSTrustDelegate(trustedCertificate: trustedCertificate)
        self.trustDelegate = trustDelegate
        session = URLSession(
            configuration: configuration,
            delegate: trustDelegate,
            delegateQueue: nil
        )
    }

    public init(session: URLSession) {
        self.session = session
        trustDelegate = nil
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw RouterOSClientError.invalidResponse
            }
            return (data, response)
        } catch {
            if let certificateFailure = trustDelegate?.certificateFailure() {
                throw certificateFailure
            }
            throw error
        }
    }
}

public struct RouterOSClient<Transport: RouterOSHTTPTransport>: Sendable {
    private let restBaseURL: URL
    private let authorizationHeader: String
    private let transport: Transport

    public init(
        baseURL: URL,
        credentials: RouterOSCredentials,
        transport: Transport
    ) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw RouterOSClientError.invalidBaseURL
        }
        guard scheme == "https" else {
            throw RouterOSClientError.insecureTransport
        }
        guard !credentials.username.isEmpty, !credentials.username.contains(":") else {
            throw RouterOSClientError.invalidUsername
        }

        let normalizedPath = baseURL.path
            .split(separator: "/")
            .map(String.init)
        switch normalizedPath {
        case []:
            restBaseURL = baseURL.appendingPathComponent("rest")
        case ["rest"]:
            restBaseURL = baseURL
        default:
            throw RouterOSClientError.invalidBaseURL
        }

        let credentialData = Data("\(credentials.username):\(credentials.password)".utf8)
        authorizationHeader = "Basic \(credentialData.base64EncodedString())"
        self.transport = transport
    }

    public func wireGuardInterfaces() async throws -> [RouterOSWireGuardInterface] {
        try await get(pathComponents: ["interface", "wireguard"])
    }

    public func wireGuardPeers() async throws -> [RouterOSWireGuardPeer] {
        try await get(pathComponents: ["interface", "wireguard", "peers"])
    }

    public func createWireGuardPeer(_ peer: RouterOSPeerCreation) async throws -> RouterOSWireGuardPeer {
        let url = ["interface", "wireguard", "peers"].reduce(restBaseURL) { url, component in
            url.appendingPathComponent(component)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(peer.requestPayload)
        do {
            return try await decodeResponse(for: request)
        } catch let error as RouterOSClientError {
            if case .httpStatus(let code, _, _) = error,
               (400 ..< 500).contains(code), code != 408 {
                throw error
            }
            throw RouterOSClientError.writeOutcomeUncertain
        } catch {
            throw RouterOSClientError.writeOutcomeUncertain
        }
    }

    private func get<Response: Decodable>(pathComponents: [String]) async throws -> Response {
        let url = pathComponents.reduce(restBaseURL) { url, component in
            url.appendingPathComponent(component)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

        return try await decodeResponse(for: request)
    }

    private func decodeResponse<Response: Decodable>(for request: URLRequest) async throws -> Response {
        let (data, response) = try await transport.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else {
            let routerError = try? JSONDecoder().decode(RouterOSErrorResponse.self, from: data)
            throw RouterOSClientError.httpStatus(
                code: response.statusCode,
                message: routerError?.message,
                detail: routerError?.detail
            )
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RouterOSClientError.invalidPayload
        }
    }
}

public extension RouterOSClient where Transport == URLSessionRouterOSHTTPTransport {
    init(
        baseURL: URL,
        credentials: RouterOSCredentials,
        trustedCertificate: RouterOSServerCertificate? = nil
    ) throws {
        try self.init(
            baseURL: baseURL,
            credentials: credentials,
            transport: URLSessionRouterOSHTTPTransport(trustedCertificate: trustedCertificate)
        )
    }
}

private struct RouterOSErrorResponse: Decodable {
    let message: String?
    let detail: String?
}
