// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Security

public struct RouterOSServerCertificate: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let derEncodedCertificate: Data
    public let fingerprintSHA256: String
    public let subjectSummary: String?

    public init(host: String, port: Int, derEncodedCertificate: Data) {
        self.host = host.lowercased()
        self.port = port
        self.derEncodedCertificate = derEncodedCertificate
        fingerprintSHA256 = Self.sha256Fingerprint(for: derEncodedCertificate)

        if let certificate = SecCertificateCreateWithData(nil, derEncodedCertificate as CFData) {
            subjectSummary = SecCertificateCopySubjectSummary(certificate) as String?
        } else {
            subjectSummary = nil
        }
    }

    public func matches(host: String, port: Int, derEncodedCertificate: Data) -> Bool {
        self.host == host.lowercased()
            && self.port == port
            && self.derEncodedCertificate == derEncodedCertificate
    }

    static func sha256Fingerprint(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

public enum RouterOSTLSCertificateError: Error, Equatable, LocalizedError, Sendable {
    case untrusted(RouterOSServerCertificate)
    case changed(expectedFingerprint: String, received: RouterOSServerCertificate)

    public var errorDescription: String? {
        switch self {
        case .untrusted:
            return "RouterOS presented a certificate that is not trusted by this Mac."
        case .changed:
            return "The RouterOS certificate has changed since it was trusted."
        }
    }
}

final class RouterOSTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trustedCertificate: RouterOSServerCertificate?
    private let failureLock = NSLock()
    private var storedCertificateFailure: RouterOSTLSCertificateError?

    init(trustedCertificate: RouterOSServerCertificate?) {
        self.trustedCertificate = trustedCertificate
    }

    func certificateFailure() -> RouterOSTLSCertificateError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return storedCertificateFailure
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificateChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCertificate = certificateChain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host.lowercased()
        let port = challenge.protectionSpace.port
        let certificateData = SecCertificateCopyData(leafCertificate) as Data
        let receivedCertificate = RouterOSServerCertificate(
            host: host,
            port: port,
            derEncodedCertificate: certificateData
        )

        if let trustedCertificate,
           trustedCertificate.host == host,
           trustedCertificate.port == port {
            guard trustedCertificate.matches(
                host: host,
                port: port,
                derEncodedCertificate: certificateData
            ) else {
                recordFailure(
                    .changed(
                        expectedFingerprint: trustedCertificate.fingerprintSHA256,
                        received: receivedCertificate
                    )
                )
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            // The exact DER certificate is pinned to this host and port. URLSession still
            // performs the TLS handshake and enforces its protocol and cipher requirements.
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            recordFailure(.untrusted(receivedCertificate))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func recordFailure(_ failure: RouterOSTLSCertificateError) {
        failureLock.lock()
        storedCertificateFailure = failure
        failureLock.unlock()
    }
}
