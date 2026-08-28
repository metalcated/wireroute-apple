// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import RouterOSKit

final class RouterOSTLSTests: XCTestCase {
    func testFormatsCertificateFingerprintAsGroupedSHA256() {
        let fingerprint = RouterOSServerCertificate.sha256Fingerprint(
            for: Data("router-cert".utf8)
        )

        XCTAssertEqual(
            fingerprint,
            "F6:34:D6:A2:2E:C7:22:6C:49:E1:CA:ED:AB:6C:CD:D5:61:0F:C9:F9:CD:AC:FA:D1:EB:89:31:B7:F0:32:0B:05"
        )
    }

    func testCertificatePinIsScopedToExactHostPortAndCertificate() {
        let certificateData = Data("router-cert".utf8)
        let certificate = RouterOSServerCertificate(
            host: "ROUTER.EXAMPLE",
            port: 443,
            derEncodedCertificate: certificateData
        )

        XCTAssertTrue(
            certificate.matches(
                host: "router.example",
                port: 443,
                derEncodedCertificate: certificateData
            )
        )
        XCTAssertFalse(
            certificate.matches(
                host: "other.example",
                port: 443,
                derEncodedCertificate: certificateData
            )
        )
        XCTAssertFalse(
            certificate.matches(
                host: "router.example",
                port: 8443,
                derEncodedCertificate: certificateData
            )
        )
        XCTAssertFalse(
            certificate.matches(
                host: "router.example",
                port: 443,
                derEncodedCertificate: Data("replacement-cert".utf8)
            )
        )
    }

    func testChangedCertificateErrorDoesNotExposeCertificateData() {
        let received = RouterOSServerCertificate(
            host: "router.example",
            port: 443,
            derEncodedCertificate: Data("replacement-cert".utf8)
        )
        let error = RouterOSTLSCertificateError.changed(
            expectedFingerprint: "AA:BB",
            received: received
        )

        XCTAssertEqual(
            error.localizedDescription,
            "The RouterOS certificate has changed since it was trusted."
        )
        XCTAssertFalse(error.localizedDescription.contains("replacement-cert"))
    }

    func testSelfSignedServerRequiresExactPinWhenIntegrationServerIsConfigured() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["WIREROUTE_TLS_INTEGRATION_URL"] else {
            throw XCTSkip("Set WIREROUTE_TLS_INTEGRATION_URL to run the local TLS integration test.")
        }
        let url = try XCTUnwrap(URL(string: rawURL))
        let host = try XCTUnwrap(url.host)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            _ = try await URLSessionRouterOSHTTPTransport().data(for: request)
            XCTFail("Expected the self-signed certificate to require explicit trust")
        } catch let error as RouterOSTLSCertificateError {
            guard case .untrusted(let received) = error else {
                return XCTFail("Expected the untrusted certificate details")
            }
            XCTAssertEqual(received.derEncodedCertificate, Self.selfSignedCertificateData)
        }

        let pin = RouterOSServerCertificate(
            host: host,
            port: url.port ?? 443,
            derEncodedCertificate: Self.selfSignedCertificateData
        )
        let (_, response) = try await URLSessionRouterOSHTTPTransport(
            trustedCertificate: pin
        ).data(for: request)
        XCTAssertEqual(response.statusCode, 200)
    }

    private static let selfSignedCertificateData = Data(
        base64Encoded: [
            "MIIDSTCCAjGgAwIBAgIUPq6Q1c5m+bcBXB2KVF1/snLvdEowDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcm91dGVyLnRl",
            "c3QwHhcNMjYwODI4MDMwMjUwWhcNMzYwODI1MDMwMjUwWjAWMRQwEgYDVQQDDAtyb3V0ZXIudGVzdDCCASIwDQYJKoZIhvcN",
            "AQEBBQADggEPADCCAQoCggEBAJ0wc48xyb6acvrpyt8fDsg21rzZWITdtOocY2G82PcnVohA5Yn3b9YVk55RWpa91CBg9/G2",
            "U+SbWlQS1wwVmypOWqBlmlUWolx03iFwk/9Z1UUNo8HlBgJvm4XxEpNTgC6ZAS5YMlnIsqQ6F7INQ09RNdsoQD205NkEgB/g",
            "jywIvVSvbeWglVe5UjMXh4s0r2cg7ijNrqa6FhUDKgYhfhViS496qIXKp8MzAoAn1coM7XoiEKpRHodYO5rSoKx2b0IcOY2/",
            "yvqXtdjCWN4gFDDsJVwqA+PPnUFkXCFm8LYJxcLo/FoJBHSd3k2eu8sTqDEHHlO4D803wmJ/l3Q6ukcCAwEAAaOBjjCBizAd",
            "BgNVHQ4EFgQUD4cQFzVMvnNqs7Ux0nmC1b9vc9QwHwYDVR0jBBgwFoAUD4cQFzVMvnNqs7Ux0nmC1b9vc9QwDAYDVR0TAQH/",
            "BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwFgYDVR0RBA8wDYILcm91dGVyLnRlc3QwDQYJKoZI",
            "hvcNAQELBQADggEBADkbCpcJZqqdwbBWc1QPKBZBXzNKjOqM6HJ9zs73ssH02f1JGC+bQqw/WBswSDYSf/xCq4Zffx4di5vS",
            "OI/s6R6IJFG71OCC+79G5+Rr+kCvz6QBmK+pqMwpFuUaAycRIYFeXZsA/Y6s1y5CYsf/uBFR8X+J2N+6vL/yyiaQy0FWGUnN",
            "5vHIe6vjM7Tkxy2bPGNoarrAix6xE70fszv5CYWpEkJBoMYDerr8+PsA2xSvCjUNufpY6hLM0T/qVUbUtVBcJJbRLuzLnGbU",
            "gejpnHrgJRyHvtcR7nTWXfqJg38BgxFlmrYKw+n2pcf9vNpddLAYlVfkYd6a8YdXgzeBcj4="
        ].joined()
    )!
}
