// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import RouterOSKit

final class RouterOSClientTests: XCTestCase {
    func testRejectsInsecureRouterURL() {
        XCTAssertThrowsError(
            try RouterOSClient(
                baseURL: URL(string: "http://router.example")!,
                credentials: RouterOSCredentials(username: "reader", password: "secret"),
                transport: StubTransport(data: Data(), statusCode: 200)
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSClientError, .insecureTransport)
        }
    }

    func testRejectsCredentialsOrQueryDataInRouterURL() {
        for value in [
            "https://reader:secret@router.example",
            "https://router.example?token=secret",
            "https://router.example/rest#fragment"
        ] {
            XCTAssertThrowsError(
                try RouterOSClient(
                    baseURL: URL(string: value)!,
                    credentials: RouterOSCredentials(username: "reader", password: "secret"),
                    transport: StubTransport(data: Data(), statusCode: 200)
                )
            ) { error in
                XCTAssertEqual(error as? RouterOSClientError, .invalidBaseURL)
            }
        }
    }

    func testCredentialsDescriptionRedactsPassword() {
        let credentials = RouterOSCredentials(username: "reader", password: "secret")

        XCTAssertTrue(credentials.description.contains("reader"))
        XCTAssertTrue(credentials.description.contains("<redacted>"))
        XCTAssertFalse(credentials.description.contains("secret"))
        XCTAssertEqual(credentials.debugDescription, credentials.description)
    }

    func testDiscoversWireGuardInterfacesUsingBasicAuthentication() async throws {
        let payload = Data("""
        [
          {
            ".id": "*3",
            "name": "wg-remote",
            "mtu": "1420",
            "listen-port": "51824",
            "public-key": "router-public-key=",
            "disabled": "false",
            "running": "true"
          }
        ]
        """.utf8)
        let transport = StubTransport(data: payload, statusCode: 200)
        let client = try RouterOSClient(
            baseURL: URL(string: "https://router.example/rest")!,
            credentials: RouterOSCredentials(username: "reader", password: "secret"),
            transport: transport
        )

        let interfaces = try await client.wireGuardInterfaces()
        let interface = try XCTUnwrap(interfaces.first)
        XCTAssertEqual(interface.id, "*3")
        XCTAssertEqual(interface.name, "wg-remote")
        XCTAssertEqual(interface.mtu, 1420)
        XCTAssertEqual(interface.listenPort, 51824)
        XCTAssertEqual(interface.publicKey, "router-public-key=")
        XCTAssertFalse(interface.isDisabled)
        XCTAssertTrue(interface.isRunning)

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/rest/interface/wireguard")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let expectedAuthorization = Data("reader:secret".utf8).base64EncodedString()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic \(expectedAuthorization)")
    }

    func testDecodesWireGuardPeerDiscoveryValues() async throws {
        let payload = Data("""
        [
          {
            ".id": "*A",
            "interface": "wg-remote",
            "name": "iPhone 12 Dev",
            "comment": "Mobile access",
            "public-key": "client-public-key=",
            "allowed-address": "10.255.100.10/32, 192.168.80.0/24",
            "endpoint-address": "",
            "endpoint-port": "0",
            "current-endpoint-address": "198.51.100.20",
            "current-endpoint-port": "51824",
            "persistent-keepalive": "25s",
            "last-handshake": "14s",
            "rx": "1024",
            "tx": "2048",
            "disabled": "false",
            "dynamic": "false",
            "responder": "true"
          }
        ]
        """.utf8)
        let transport = StubTransport(data: payload, statusCode: 200)
        let client = try RouterOSClient(
            baseURL: URL(string: "https://router.example")!,
            credentials: RouterOSCredentials(username: "reader", password: "secret"),
            transport: transport
        )

        let peers = try await client.wireGuardPeers()
        let peer = try XCTUnwrap(peers.first)

        XCTAssertEqual(peer.id, "*A")
        XCTAssertEqual(peer.interfaceName, "wg-remote")
        XCTAssertEqual(peer.name, "iPhone 12 Dev")
        XCTAssertEqual(peer.allowedAddresses, ["10.255.100.10/32", "192.168.80.0/24"])
        XCTAssertEqual(peer.currentEndpointAddress, "198.51.100.20")
        XCTAssertEqual(peer.currentEndpointPort, 51824)
        XCTAssertEqual(peer.lastHandshake, "14s")
        XCTAssertEqual(peer.receivedBytes, 1024)
        XCTAssertEqual(peer.transmittedBytes, 2048)
        XCTAssertTrue(peer.isResponder)

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/rest/interface/wireguard/peers")
    }

    func testSurfacesRouterOSErrorWithoutLeakingResponseData() async throws {
        let payload = Data("""
        {"error":401,"message":"Unauthorized","detail":"invalid credentials"}
        """.utf8)
        let transport = StubTransport(data: payload, statusCode: 401)
        let client = try RouterOSClient(
            baseURL: URL(string: "https://router.example")!,
            credentials: RouterOSCredentials(username: "reader", password: "wrong"),
            transport: transport
        )

        do {
            _ = try await client.wireGuardInterfaces()
            XCTFail("Expected an HTTP status error")
        } catch let error as RouterOSClientError {
            XCTAssertEqual(
                error,
                .httpStatus(code: 401, message: "Unauthorized", detail: "invalid credentials")
            )
        }
    }
}

private actor StubTransport: RouterOSHTTPTransport {
    private let responseData: Data
    private let statusCode: Int
    private var requests = [URLRequest]()

    init(data: Data, statusCode: Int) {
        responseData = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (responseData, response)
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }
}
