import Foundation
import NIOSSL

/// Client certificates for gRPC's TLS stack, which takes DER bytes; both
/// PKCS#12 and PEM files work here.
enum GrpcCertificates {
    @MainActor
    static func load(_ certificate: OCClientCertificate, variables: [String: String], base: URL?) throws -> (certificateDER: [UInt8], privateKeyDER: [UInt8]) {
        let value = { OpenCollectionDocument.interpolate($0, variables) }
        let path = EffectiveBody.resolvePath(value(certificate.path), base: base).path
        let passphrase = Array(value(certificate.passphrase).utf8)
        do {
            if certificate.type == "pem" {
                let cert = try NIOSSLCertificate.fromPEMFile(path)
                guard let first = cert.first else { throw NetworkError.unreadableCertificate(path) }
                let keyPath = EffectiveBody.resolvePath(value(certificate.keyPath), base: base).path
                let key = passphrase.isEmpty
                    ? try NIOSSLPrivateKey(file: keyPath, format: .pem)
                    : try NIOSSLPrivateKey(file: keyPath, format: .pem) { callback in callback(passphrase) }
                return (try first.toDERBytes(), try key.derBytes)
            }
            let bundle = try NIOSSLPKCS12Bundle(file: path, passphrase: passphrase.isEmpty ? nil : passphrase)
            guard let first = bundle.certificateChain.first else { throw NetworkError.unreadableCertificate(path) }
            return (try first.toDERBytes(), try bundle.privateKey.derBytes)
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.badCertificate(URL(fileURLWithPath: path).lastPathComponent, -1)
        }
    }
}
