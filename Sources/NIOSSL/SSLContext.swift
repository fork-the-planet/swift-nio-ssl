//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

#if compiler(>=6.1)
internal import CNIOBoringSSL
internal import CNIOBoringSSLShims
#else
@_implementationOnly import CNIOBoringSSL
@_implementationOnly import CNIOBoringSSLShims
#endif

#if canImport(Darwin)
import Darwin.C
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#else
#error("unsupported os")
#endif

// This is a neat trick. Swift lazily initializes module-globals based on when they're first
// used. This lets us defer BoringSSL intialization as late as possible and only do it if people
// actually create any object that uses BoringSSL.
internal let boringSSLIsInitialized: Bool = initializeBoringSSL()

internal enum FileSystemObject {
    case directory
    case file

    static internal func pathType(path: String) -> FileSystemObject? {
        var statObj = stat()
        do {
            try Posix.stat(path: path, buf: &statObj)
        } catch {
            return nil
        }

        #if os(Android) && arch(arm)
        return (statObj.st_mode & UInt32(S_IFDIR)) != 0 ? .directory : .file
        #else
        return (statObj.st_mode & S_IFDIR) != 0 ? .directory : .file
        #endif
    }
}

// This bizarre extension to UnsafeBufferPointer is very useful for handling ALPN identifiers. BoringSSL
// likes to work with them in wire format, so rather than us decoding them we can just encode ours to
// the wire format and then work with them from there.
extension UnsafeBufferPointer where Element == UInt8 {
    fileprivate func locateAlpnIdentifier(identifier: UnsafeBufferPointer<Element>) -> (index: Int, length: Int)? {
        precondition(identifier.count != 0)
        let targetLength = Int(identifier[0])

        var index = 0
        outerLoop: while index < self.count {
            let length = Int(self[index])
            guard index + length + 1 <= self.count else {
                // Invalid length of ALPN identifier, no match.
                return nil
            }

            guard targetLength == length else {
                index += length + 1
                continue outerLoop
            }

            for innerIndex in 1...length {
                guard identifier[innerIndex] == self[index + innerIndex] else {
                    index += length + 1
                    continue outerLoop
                }
            }

            // Found it
            return (index: index + 1, length: length)
        }
        return nil
    }
}

private func alpnCallback(
    ssl: OpaquePointer?,
    out: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
    outlen: UnsafeMutablePointer<UInt8>?,
    in: UnsafePointer<UInt8>?,
    inlen: UInt32,
    appData: UnsafeMutableRawPointer?
) -> CInt {
    // Perform some soundness checks. We don't want NULL pointers around here.
    guard let ssl = ssl, let out = out, let outlen = outlen, let `in` = `in` else {
        return SSL_TLSEXT_ERR_NOACK
    }

    // We want to take the SSL pointer and extract the parent Swift object.
    let parentSwiftContext = NIOSSLContext.lookupFromRawContext(ssl: ssl)

    let offeredProtocols = UnsafeBufferPointer(start: `in`, count: Int(inlen))
    guard let (index, length) = parentSwiftContext.alpnSelectCallback(offeredProtocols: offeredProtocols) else {
        out.pointee = nil
        outlen.pointee = 0
        return SSL_TLSEXT_ERR_NOACK
    }

    out.pointee = `in` + index
    outlen.pointee = UInt8(length)
    return SSL_TLSEXT_ERR_OK
}

/// PSK Callback for the server side context.
private func serverPSKCallback(
    ssl: OpaquePointer?,
    identity: UnsafePointer<CChar>?,
    psk: UnsafeMutablePointer<UInt8>?,
    max_psk_len: UInt32
) -> UInt32 {

    guard let ssl = ssl else { return 0 }

    // Initial implementation only supports TLS 1.2 due API support exposed from BoringSSL.
    // TODO (meaton) add TLS 1.3 support when available.

    let parentSwiftContext = NIOSSLContext.lookupFromRawContext(ssl: ssl)

    guard let serverCallback = parentSwiftContext.pskServerConfigurationCallback,
        let unwrappedIdentity = identity,  // Incoming identity
        let strIdentity = String(validatingUTF8: unwrappedIdentity),
        let outputPSK = psk  // Output PSK key.
    else {
        return 0
    }

    // Take the hint and the possible identity and pass them down to the callback to get associated PSK from callback
    var identityResponse: PSKServerIdentityResponse? = nil
    switch serverCallback {
    case .callback(let callback):
        // Deprecated callback doesn't accept optional hint value
        guard let hint = parentSwiftContext.configuration.pskHint else { return 0 }
        identityResponse = try? callback(hint, strIdentity)
    case .provider(let provider):
        identityResponse = try? provider(
            PSKServerContext(
                hint: parentSwiftContext.configuration.pskHint,
                clientIdentity: strIdentity,
                maxPSKLength: Int(max_psk_len)
            )
        )
    }
    guard let identityResponse else {
        return 0
    }
    let serverPSK = identityResponse.key  // From the callback

    // Make sure the key is returned by the callback and it is of proper length, otherwise, fail.
    if serverPSK.isEmpty || serverPSK.count > max_psk_len {
        return 0
    }
    let _ = serverPSK.withUnsafeBytes { (body: UnsafeRawBufferPointer) -> Void in
        memcpy(outputPSK, body.baseAddress!, body.count)
    }
    return UInt32(serverPSK.count)
}

/// PSK Callback for the client side context.
private func clientPSKCallback(
    ssl: OpaquePointer?,
    hint: UnsafePointer<CChar>?,
    identity: UnsafeMutablePointer<CChar>?,
    max_identity_len: UInt32,
    psk: UnsafeMutablePointer<UInt8>?,
    max_psk_len: UInt32
) -> UInt32 {

    guard let ssl = ssl else { return 0 }

    let parentSwiftContext = NIOSSLContext.lookupFromRawContext(ssl: ssl)

    guard let clientCallback = parentSwiftContext.pskClientConfigurationCallback,
        let unwrappedIdentity = identity,  // Output identity that will be later be mapped from client callback
        let outputPSK = psk  // Output PSK key that will later be mapped from client callback
    else {
        return 0
    }

    // If set, build out a hint otherwise fallback to an empty string and pass it into the client callback.
    let clientHint: String? = hint.flatMap({ String(validatingUTF8: $0) })

    // Take the hint and pass it down to the callback to get associated PSK from callback
    let pskIdentity: PSKClientIdentityResponse?
    switch clientCallback {
    case .callback(let callback):
        // Deprecated callback doesn't accept optional hint value
        guard let clientHint else { return 0 }
        pskIdentity = try? callback(clientHint)
    case .provider(let provider):
        pskIdentity = try? provider(
            PSKClientContext(
                hint: clientHint,
                maxPSKLength: Int(max_psk_len)
            )
        )
    }
    guard let pskIdentity else { return 0 }

    let clientPSK = pskIdentity.key  // Key from the callback
    let clientIdentity = pskIdentity.identity

    // Use max_identity_len so it does not trigger an overrun.
    if clientIdentity.utf8.isEmpty || clientIdentity.utf8.count > max_identity_len {
        return 0
    }

    // Map the output identity from the one passed back from the callback.
    // This helps populate the server callback for the key exchange.
    let _ = clientIdentity.withCString { ptr in
        memcpy(unwrappedIdentity, ptr, clientIdentity.utf8.count)
    }

    if clientPSK.isEmpty || clientPSK.count > max_psk_len {
        return 0
    }
    let _ = clientPSK.withUnsafeBytes { (body: UnsafeRawBufferPointer) -> Void in
        memcpy(outputPSK, body.baseAddress!, body.count)
    }
    return UInt32(clientPSK.count)
}

private func sslContextCallback(ssl: OpaquePointer?, arg: UnsafeMutableRawPointer?) -> Int32 {
    guard let ssl = ssl else {
        preconditionFailure(
            """
                SSL_CTX_set_cert_cb was executed with an invalid ssl pointer.
                This should not be possible, please file an issue.
            """
        )
    }

    let parentSwiftContext = SSLConnection.loadConnectionFromSSL(ssl)

    // This is a safe force unwrap as this callback is only register directly after setting the manager
    var contextManager = parentSwiftContext.customContextManager!

    // Begin loading a new context
    let result = contextManager.loadContext(ssl: ssl)

    switch result {
    case .none:
        // If we dont have a result yet then we must suspend
        return -1
    case .failure:
        // If loading a context failed then we must signal as such
        return 0
    case .success(let changes):
        do {
            // Attempt to load the new certificate chain and abort on failure
            let ssl = SSLConnection.loadConnectionFromSSL(ssl)
            try ssl.applyOverride(changes)

            // We must return 1 to signal a successful load of the new context
            return 1
        } catch {
            // Althought the load was successful, the context changes failed and we must mark as such
            contextManager.setLoadContextError(error)
            return 0
        }
    }
}

/// A wrapper class that encapsulates BoringSSL's `SSL_CTX *` object.
///
/// This object is thread-safe and can be shared across TLS connections in your application. Even if the connections
/// are associated with `Channel`s from different `EventLoop`s.
///
/// > Note: Creating a ``NIOSSLContext`` is a very expensive operation because BoringSSL will usually need to load and
///         parse large number of certificates from the system trust store. Therefore, creating a
///         ``NIOSSLContext`` will likely allocate many thousand times and will also _perform blocking disk I/O_.
///
/// > Warning: Avoid creating ``NIOSSLContext``s on any `EventLoop` because it does _blocking disk I/O_.
public final class NIOSSLContext {
    fileprivate let sslContext: OpaquePointer
    private let callbackManager: CallbackManagerProtocol?
    private var keyLogManager: KeyLogCallbackManager?
    internal var pskClientConfigurationCallback: _NIOPSKClientIdentityProvider?
    internal var pskServerConfigurationCallback: _NIOPSKServerIdentityProvider?
    internal let configuration: TLSConfiguration

    /// Initialize a context that will create multiple connections, all with the same
    /// configuration.
    internal init(
        configuration: TLSConfiguration,
        callbackManager: CallbackManagerProtocol?
    ) throws {
        guard boringSSLIsInitialized else { fatalError("Failed to initialize BoringSSL") }
        guard let context = CNIOBoringSSL_SSL_CTX_new(CNIOBoringSSL_TLS_method()) else {
            fatalError("Failed to create new BoringSSL context")
        }

        let minTLSVersion: CInt
        switch configuration.minimumTLSVersion {
        case .tlsv13:
            minTLSVersion = TLS1_3_VERSION
        case .tlsv12:
            minTLSVersion = TLS1_2_VERSION
        case .tlsv11:
            minTLSVersion = TLS1_1_VERSION
        case .tlsv1:
            minTLSVersion = TLS1_VERSION
        }
        var returnCode = CNIOBoringSSL_SSL_CTX_set_min_proto_version(context, UInt16(minTLSVersion))
        precondition(1 == returnCode)

        let maxTLSVersion: CInt

        switch configuration.maximumTLSVersion {
        case .some(.tlsv1):
            maxTLSVersion = TLS1_VERSION
        case .some(.tlsv11):
            maxTLSVersion = TLS1_1_VERSION
        case .some(.tlsv12):
            maxTLSVersion = TLS1_2_VERSION
        case .some(.tlsv13), .none:
            // Unset defaults to TLS1.3 for now. BoringSSL's default is TLS 1.2.
            maxTLSVersion = TLS1_3_VERSION
        }
        returnCode = CNIOBoringSSL_SSL_CTX_set_max_proto_version(context, UInt16(maxTLSVersion))
        precondition(1 == returnCode)

        // Cipher suites. We just pass this straight to BoringSSL.
        returnCode = CNIOBoringSSL_SSL_CTX_set_cipher_list(context, configuration.cipherSuites)
        precondition(1 == returnCode)

        // Curves list.
        if let curves = configuration.curves {
            returnCode =
                curves
                .map { $0.rawValue }
                .withUnsafeBufferPointer { algo in
                    CNIOBoringSSL_SSL_CTX_set1_group_ids(context, algo.baseAddress, algo.count)
                }
            if returnCode != 1 {
                let errorStack = BoringSSLError.buildErrorStack()
                throw BoringSSLError.unknownError(errorStack)
            }
        }

        // Set the PSK Client Configuration callback.
        if let pskClientConfigurationsCallback = configuration._pskClientIdentityProvider {
            self.pskClientConfigurationCallback = pskClientConfigurationsCallback
            CNIOBoringSSL_SSL_CTX_set_psk_client_callback(context, clientPSKCallback)
        }

        // Set the PSK Server Configuration callback.
        if let pskServerConfigurationCallback = configuration._pskServerIdentityProvider {
            self.pskServerConfigurationCallback = pskServerConfigurationCallback
            CNIOBoringSSL_SSL_CTX_set_psk_server_callback(context, serverPSKCallback)
        }

        // Set the SSL Context Configuration callback.
        // The state is managed on the connection.
        if configuration.sslContextCallback != nil {
            CNIOBoringSSL_SSL_CTX_set_cert_cb(context, sslContextCallback, nil)
        }

        // Set the hint no matter if it is client or server side.
        if let pskHint = configuration.pskHint {
            CNIOBoringSSL_SSL_CTX_use_psk_identity_hint(context, pskHint)
        }

        // On non-Linux platforms, when using the platform default trust roots, we make use of a
        // custom verify callback. If we have also been presented with additional trust roots of
        // type `.file`, we take the opportunity now to load them in memory to avoid doing so
        // repeatedly on the request path.
        //
        // However, to avoid closely coupling this code with other parts (e.g. the platform-specific
        // concerns, and the defaulting of `trustRoots` to `.default` when `nil`), we unilaterally
        // convert any `additionalTrustRoots` of type `.file` to `.certificates`.
        var configuration = configuration
        configuration.additionalTrustRoots = try configuration.additionalTrustRoots.map { trustRoots in
            switch trustRoots {
            case .file(let path):
                return .certificates(try NIOSSLCertificate.fromPEMFile(path))
            default:
                return trustRoots
            }
        }

        // Configure certificate validation
        try NIOSSLContext.configureCertificateValidation(
            context: context,
            verification: configuration.certificateVerification,
            trustRoots: configuration.trustRoots,
            additionalTrustRoots: configuration.additionalTrustRoots,
            sendCANames: configuration.sendCANameList
        )

        // Configure verification algorithms
        if let verifySignatureAlgorithms = configuration.verifySignatureAlgorithms {
            returnCode =
                verifySignatureAlgorithms
                .map { $0.rawValue }
                .withUnsafeBufferPointer { algo in
                    CNIOBoringSSL_SSL_CTX_set_verify_algorithm_prefs(context, algo.baseAddress, algo.count)
                }
            if returnCode != 1 {
                let errorStack = BoringSSLError.buildErrorStack()
                throw BoringSSLError.unknownError(errorStack)
            }
        }

        // Configure signing algorithms
        if let signingSignatureAlgorithms = configuration.resolvedSigningSignatureAlgorithms {
            returnCode =
                signingSignatureAlgorithms
                .map { $0.rawValue }
                .withUnsafeBufferPointer { algo in
                    CNIOBoringSSL_SSL_CTX_set_signing_algorithm_prefs(context, algo.baseAddress, algo.count)
                }
            if returnCode != 1 {
                let errorStack = BoringSSLError.buildErrorStack()
                throw BoringSSLError.unknownError(errorStack)
            }
        }

        // If we were given a certificate chain to use, load it and its associated private key. Before
        // we do, set up a passphrase callback if we need to.
        if let callbackManager = callbackManager {
            CNIOBoringSSL_SSL_CTX_set_default_passwd_cb(
                context,
                { globalBoringSSLPassphraseCallback(buf: $0, size: $1, rwflag: $2, u: $3) }
            )
            CNIOBoringSSL_SSL_CTX_set_default_passwd_cb_userdata(
                context,
                Unmanaged.passUnretained(callbackManager as AnyObject).toOpaque()
            )
        }

        let handle = UnsafeKeyAndChainTarget.sslContext(context)
        try handle.useCertificateChain(configuration.certificateChain)

        if let pkey = configuration.privateKey {
            try handle.usePrivateKeySource(pkey)
        }

        if configuration.encodedApplicationProtocols.count > 0 {
            try NIOSSLContext.setAlpnProtocols(configuration.encodedApplicationProtocols, context: context)
            NIOSSLContext.setAlpnCallback(context: context)
        }

        // Add a key log callback.
        if let keyLogCallback = configuration.keyLogCallback {
            self.keyLogManager = KeyLogCallbackManager(callback: keyLogCallback)
            try NIOSSLContext.setKeylogCallback(context: context)
        } else {
            self.keyLogManager = nil
        }

        self.sslContext = context
        self.configuration = configuration
        self.callbackManager = callbackManager

        // Always make it possible to get from an SSL_CTX structure back to this.
        let ptrToSelf = Unmanaged.passUnretained(self).toOpaque()
        CNIOBoringSSLShims_SSL_CTX_set_app_data(context, ptrToSelf)
    }

    /// Initialize a context that will create multiple connections, all with the same
    /// configuration.
    ///
    /// - Note: Creating a ``NIOSSLContext`` is a very expensive operation because BoringSSL will usually need to load and
    ///         parse large number of certificates from the system trust store. Therefore, creating a
    ///         ``NIOSSLContext`` will likely allocate many thousand times and will also _perform blocking disk I/O_.
    ///
    /// - Warning: Avoid creating ``NIOSSLContext``s on any `EventLoop` because it does _blocking disk I/O_.
    public convenience init(configuration: TLSConfiguration) throws {
        try self.init(configuration: configuration, callbackManager: nil)
    }

    /// Initialize a context that will create multiple connections, all with the same
    /// configuration, along with a callback that will be called when needed to decrypt any
    /// encrypted private keys.
    ///
    /// - Note: Creating a ``NIOSSLContext`` is a very expensive operation because BoringSSL will usually need to load and
    ///         parse large number of certificates from the system trust store. Therefore, creating a
    ///         ``NIOSSLContext`` will likely allocate many thousand times and will also _perform blocking disk I/O_.
    ///
    /// - Warning: Avoid creating ``NIOSSLContext``s on any `EventLoop` because it does _blocking disk I/O_.
    ///
    /// - parameters:
    ///     - configuration: The ``TLSConfiguration`` to use for all the connections with this
    ///         ``NIOSSLContext``.
    ///     - passphraseCallback: The callback to use to decrypt any private keys used by this
    ///         ``NIOSSLContext``. For more details on this parameter see the documentation for
    ///         ``NIOSSLPassphraseCallback``.
    public convenience init<T: Collection>(
        configuration: TLSConfiguration,
        passphraseCallback: @escaping NIOSSLPassphraseCallback<T>
    ) throws where T.Element == UInt8 {
        let manager = BoringSSLPassphraseCallbackManager(userCallback: passphraseCallback)
        try self.init(configuration: configuration, callbackManager: manager)
    }

    /// Create a new connection object with the configuration from this
    /// context.
    internal func createConnection() -> SSLConnection? {
        guard let ssl = CNIOBoringSSL_SSL_new(self.sslContext) else {
            return nil
        }

        let conn = SSLConnection(ownedSSL: ssl, parentContext: self)

        // If we need to turn on the validation on Apple platforms, do it here.
        #if canImport(Darwin)
        switch self.configuration.trustRoots {
        case .some(.default), .none:
            conn.setCustomVerificationCallback(
                CustomVerifyManager(callback: {
                    do {
                        conn.performSecurityFrameworkValidation(
                            promise: $0,
                            peerCertificates: try conn.getPeerCertificatesAsSecCertificate()
                        )
                    } catch {
                        $0.fail(error)
                    }
                })
            )
        case .some(.certificates), .some(.file):
            break
        }
        #endif

        return conn
    }

    fileprivate func alpnSelectCallback(offeredProtocols: UnsafeBufferPointer<UInt8>) -> (index: Int, length: Int)? {
        for possibility in configuration.encodedApplicationProtocols {
            let match = possibility.withUnsafeBufferPointer {
                offeredProtocols.locateAlpnIdentifier(identifier: $0)
            }
            if match != nil { return match }
        }

        return nil
    }

    deinit {
        CNIOBoringSSL_SSL_CTX_free(self.sslContext)
    }
}

// NIOSSLContext is thread-safe and therefore Sendable
extension NIOSSLContext: @unchecked Sendable {}

extension NIOSSLContext {
    fileprivate static func lookupFromRawContext(ssl: OpaquePointer) -> NIOSSLContext {
        // We want to take the SSL pointer and extract the parent Swift object. These force-unwraps are for
        // safety: a correct NIO program can never fail to set these pointers, and if it does failing loudly is
        // more useful than failing quietly.
        let parentCtx = CNIOBoringSSL_SSL_get_SSL_CTX(ssl)!
        let parentPtr = CNIOBoringSSLShims_SSL_CTX_get_app_data(parentCtx)!
        let parentSwiftContext: NIOSSLContext = Unmanaged.fromOpaque(parentPtr).takeUnretainedValue()
        return parentSwiftContext
    }
}

extension NIOSSLContext {
    private static func setAlpnProtocols(_ protocols: [[UInt8]], context: OpaquePointer) throws {
        // This copy should be done infrequently, so we don't worry too much about it.
        let protoBuf = protocols.reduce([UInt8](), +)
        let rc = protoBuf.withUnsafeBufferPointer {
            CNIOBoringSSL_SSL_CTX_set_alpn_protos(context, $0.baseAddress!, $0.count)
        }

        // Annoyingly this function reverses the error convention: 0 is success, non-zero is failure.
        if rc != 0 {
            let errorStack = BoringSSLError.buildErrorStack()
            throw BoringSSLError.failedToSetALPN(errorStack)
        }
    }

    private static func setAlpnCallback(context: OpaquePointer) {
        // This extra closure here is very silly, but it exists to allow us to avoid writing down the type of the first
        // argument. Combined with the helper above, the compiler will be able to solve its way to success here.
        CNIOBoringSSL_SSL_CTX_set_alpn_select_cb(
            context,
            { alpnCallback(ssl: $0, out: $1, outlen: $2, in: $3, inlen: $4, appData: $5) },
            nil
        )
    }
}

// Configuring certificate verification
extension NIOSSLContext {
    private static func configureCertificateValidation(
        context: OpaquePointer,
        verification: CertificateVerification,
        trustRoots: NIOSSLTrustRoots?,
        additionalTrustRoots: [NIOSSLAdditionalTrustRoots],
        sendCANames: Bool
    ) throws {
        // If validation is turned on, set the trust roots and turn on cert validation.
        switch verification {
        case .fullVerification, .noHostnameVerification:
            CNIOBoringSSL_SSL_CTX_set_verify(context, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil)

            // Also, set TRUSTED_FIRST to work around dumb clients that don't know what they're doing and send
            // untrusted root certs. X509_VERIFY_PARAM will or-in the flags, so we don't need to load them first.
            // This is get0 so we can just ignore the pointer, we don't have an owned ref.
            let trustParams = CNIOBoringSSL_SSL_CTX_get0_param(context)!
            CNIOBoringSSL_X509_VERIFY_PARAM_set_flags(trustParams, CUnsignedLong(X509_V_FLAG_TRUSTED_FIRST))

            func configureTrustRoots(trustRoots: NIOSSLTrustRoots) throws {
                switch trustRoots {
                case .default:
                    try NIOSSLContext.platformDefaultConfiguration(context: context)
                case .file(let path):
                    try NIOSSLContext.loadVerifyLocations(path, context: context, sendCANames: sendCANames)
                case .certificates(let certs):
                    for cert in certs {
                        try NIOSSLContext.addRootCertificate(cert, context: context)
                        // Add the CA name from the trust root
                        if sendCANames {
                            try NIOSSLContext.addCACertificateNameToList(context: context, certificate: cert)
                        }
                    }
                }
            }
            try configureTrustRoots(trustRoots: trustRoots ?? .default)
            for root in additionalTrustRoots { try configureTrustRoots(trustRoots: .init(from: root)) }
        default:
            break
        }
    }

    private static func addCACertificateNameToList(context: OpaquePointer, certificate: NIOSSLCertificate) throws {
        // Adds the CA name extracted from cert to the list of CAs sent to the client when requesting a client certificate.
        try certificate.withUnsafeMutableX509Pointer { ref in
            guard 1 == CNIOBoringSSL_SSL_CTX_add_client_CA(context, ref) else {
                throw NIOSSLError.failedToLoadCertificate
            }
        }
    }

    private static func loadVerifyLocations(_ path: String, context: OpaquePointer, sendCANames: Bool) throws {
        let isDirectory: Bool
        switch FileSystemObject.pathType(path: path) {
        case .some(.directory):
            isDirectory = true
        case .some(.file):
            isDirectory = false
        case .none:
            throw NIOSSLError.noSuchFilesystemObject
        }

        let result = path.withCString { (pointer) -> CInt in
            let file = !isDirectory ? pointer : nil
            let directory = isDirectory ? pointer : nil
            return CNIOBoringSSL_SSL_CTX_load_verify_locations(context, file, directory)
        }

        if result == 0 {
            let errorStack = BoringSSLError.buildErrorStack()
            throw BoringSSLError.unknownError(errorStack)
        } else if sendCANames, !isDirectory {
            // For single CA file, add the CA name from the trust root.
            // This could be from a location like /etc/ssl/cert.pem as an example.
            CNIOBoringSSL_SSL_CTX_set_client_CA_list(context, CNIOBoringSSL_SSL_load_client_CA_file(path))
        } else if sendCANames, isDirectory {
            // Match the c_rehash directory format and load the certificate based on this criteria.
            let certificateFilePaths = try DirectoryContents(path: path).filter {
                try self._isRehashFormat(path: $0)
            }
            // Load only the certificates that resolve to an existing certificate in the directory.
            for symPath in certificateFilePaths {
                // c_rehash only support pem files.
                let cert = try NIOSSLCertificate(file: symPath, format: .pem)
                try addCACertificateNameToList(context: context, certificate: cert)
            }
        }
    }

    private static func addRootCertificate(_ cert: NIOSSLCertificate, context: OpaquePointer) throws {
        let store = CNIOBoringSSL_SSL_CTX_get_cert_store(context)!
        let rc = cert.withUnsafeMutableX509Pointer { ref in
            CNIOBoringSSL_X509_STORE_add_cert(store, ref)
        }
        if 0 == rc {
            throw NIOSSLError.failedToLoadCertificate
        }
    }

    private static func platformDefaultConfiguration(context: OpaquePointer) throws {
        // Platform default trust is configured differently in different places.
        // On Linux, we use our searched heuristics to guess about where the platform trust store is.
        // On Darwin, we use a custom callback that is set later, in createConnection
        #if os(Linux)
        let result = rootCAFilePath.withCString { rootCAFilePointer in
            rootCADirectoryPath.withCString { rootCADirectoryPointer in
                CNIOBoringSSL_SSL_CTX_load_verify_locations(context, rootCAFilePointer, rootCADirectoryPointer)
            }
        }

        if result == 0 {
            let errorStack = BoringSSLError.buildErrorStack()
            throw BoringSSLError.unknownError(errorStack)
        }
        #elseif os(Android)
        let result = rootCADirectoryPath.withCString { rootCADirectoryPointer in
            CNIOBoringSSL_SSL_CTX_load_verify_locations(context, nil, rootCADirectoryPointer)
        }

        if result == 0 {
            let errorStack = BoringSSLError.buildErrorStack()
            throw BoringSSLError.unknownError(errorStack)
        }
        #endif
    }

    private static func setKeylogCallback(context: OpaquePointer) throws {
        CNIOBoringSSL_SSL_CTX_set_keylog_callback(context) { (ssl, linePointer) in
            guard let ssl = ssl, let linePointer = linePointer else {
                return
            }

            let parentSwiftContext = NIOSSLContext.lookupFromRawContext(ssl: ssl)

            // Similarly, this force-unwrap is safe because a correct NIO program can never fail to unwrap this entry
            // either.
            parentSwiftContext.keyLogManager!.log(linePointer)
        }
    }

    /// Takes a path and determines if the file at this path is of c_rehash format .
    internal static func _isRehashFormat(path: String) throws -> Bool {
        // Check if the element’s name matches the c_rehash symlink name format.
        // The links created are of the form HHHHHHHH.D, where each H is a hexadecimal character and D is a single decimal digit.
        let utf8PathView = path.utf8
        let utf8PathSplitView = utf8PathView.split(separator: UInt8(ascii: "/"))

        // Make sure the path is at least 10 units long
        guard let lastPathComponent = utf8PathSplitView.last,
            lastPathComponent.count == 10
        else { return false }
        // Split into filename parts HHHHHHHH.D -> [[HHHHHHHH], [D]]
        let filenameParts = lastPathComponent.split(separator: UInt8(ascii: "."))

        // Double check that the extension did not fail to cast to an integer.
        // Make sure that the filename is an 8 character hex based file name.
        guard filenameParts.count == 2,
            let filename = filenameParts.first,
            let fileExtension = filenameParts.last,
            fileExtension.count == 1,
            filename.count == 8,
            filename.allSatisfy({ $0.isHexDigit }),
            fileExtension.first == UInt8(ascii: "0")
        else { return false }

        // Check if the element is a symlink. If it is not, return false.
        var buffer = stat()
        let _ = try Posix.lstat(path: path, buf: &buffer)
        // Check the mode to make sure this is a symlink
        #if os(Android) && arch(arm)
        if (buffer.st_mode & UInt32(S_IFMT)) != UInt32(S_IFLNK) { return false }
        #else
        if (buffer.st_mode & S_IFMT) != S_IFLNK { return false }
        #endif

        // Return true at this point because the file format is considered to be in rehash format and a symlink.
        // Rehash format being "%08lx.%d" or HHHHHHHH.D
        return true
    }
}

extension NIOSSLContext {
    /// Exposes the CA Name list count from BoringSSL's STACK_OF(X509_NAME)
    func getX509NameListCount() -> Int {
        guard let caNameList = CNIOBoringSSL_SSL_CTX_get_client_CA_list(self.sslContext) else {
            return 0
        }
        return CNIOBoringSSL_sk_X509_NAME_num(caNameList)
    }
}

// For accessing STACK_OF(SSL_CIPHER) from a SSLContext
extension NIOSSLContext {
    /// A collection of buffers representing a STACK_OF(SSL_CIPHER)
    struct NIOTLSCipherBuffers {
        private let basePointer: OpaquePointer

        fileprivate init(basePointer: OpaquePointer) {
            self.basePointer = basePointer
        }
    }

    /// Invokes a block with a collection of pointers to STACK_OF(SSL_CIPHER).
    ///
    /// The pointers are only guaranteed to be valid for the duration of this call.  This method aligns with the RandomAccessCollection protocol
    /// to access UInt16 pointers at a specific index.  This pointer is used to safely access id values of the cipher to create a new NIOTLSCipher.
    fileprivate func withStackOfCipherSuiteBuffers<Result>(
        _ body: (NIOTLSCipherBuffers?) throws -> Result
    ) rethrows -> Result {
        guard let stackPointer = CNIOBoringSSL_SSL_CTX_get_ciphers(self.sslContext) else {
            return try body(nil)
        }
        return try body(NIOTLSCipherBuffers(basePointer: stackPointer))
    }

    /// Access cipher suites applied to the context
    internal var cipherSuites: [NIOTLSCipher] {
        self.withStackOfCipherSuiteBuffers { buffers in
            guard let buffers = buffers else {
                return []
            }
            return Array(buffers)
        }
    }
}

extension NIOSSLContext.NIOTLSCipherBuffers: RandomAccessCollection {

    struct Index: Hashable, Comparable, Strideable {
        typealias Stride = Int

        fileprivate var index: Int

        fileprivate init(_ index: Int) {
            self.index = index
        }

        static func < (lhs: Index, rhs: Index) -> Bool {
            lhs.index < rhs.index
        }

        func advanced(by n: NIOSSLContext.NIOTLSCipherBuffers.Index.Stride) -> NIOSSLContext.NIOTLSCipherBuffers.Index {
            var result = self
            result.index += n
            return result
        }

        func distance(
            to other: NIOSSLContext.NIOTLSCipherBuffers.Index
        ) -> NIOSSLContext.NIOTLSCipherBuffers.Index.Stride {
            other.index - self.index
        }
    }

    typealias Element = NIOTLSCipher

    var startIndex: Index {
        Index(0)
    }

    var endIndex: Index {
        Index(self.count)
    }

    var count: Int {
        CNIOBoringSSL_sk_SSL_CIPHER_num(self.basePointer)
    }

    subscript(position: Index) -> NIOTLSCipher {
        precondition(position < self.endIndex)
        precondition(position >= self.startIndex)
        guard let ptr = CNIOBoringSSL_sk_SSL_CIPHER_value(self.basePointer, position.index) else {
            preconditionFailure("Unable to locate backing pointer.")
        }
        let cipherID = CNIOBoringSSL_SSL_CIPHER_get_protocol_id(ptr)
        return NIOTLSCipher(cipherID)
    }
}

extension Optional where Wrapped == String {
    internal func withCString<Result>(_ body: (UnsafePointer<CChar>?) throws -> Result) rethrows -> Result {
        switch self {
        case .some(let s):
            return try s.withCString({ try body($0) })
        case .none:
            return try body(nil)
        }
    }
}

internal class DirectoryContents: Sequence, IteratorProtocol {

    typealias Element = String
    let path: String
    // Used to account between the differences of DIR being defined on Darwin.
    // Otherwise an OpaquePointer needs to be used to account for the non-defined type in glibc.
    #if canImport(Darwin)
    let dir: UnsafeMutablePointer<DIR>
    #else
    let dir: OpaquePointer
    #endif

    init(path: String) {
        self.path = path
        self.dir = opendir(path)!
    }

    func next() -> String? {
        if let dirent: UnsafeMutablePointer<dirent> = readdir(self.dir) {
            let name = withUnsafePointer(to: &dirent.pointee.d_name) { (ptr) -> String in
                // Pointers to homogeneous tuples in Swift are always bound to both the tuple type and the element type,
                // so the assumption below is safe.
                let elementPointer = UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                return String(cString: elementPointer)
            }
            return self.path + name
        }
        return nil
    }

    deinit {
        closedir(dir)
    }
}

// Used as part of the `_isRehashFormat` format to determine if the filename is a hexadecimal filename.
extension UTF8.CodeUnit {
    private static let asciiZero = UInt8(ascii: "0")
    private static let asciiNine = UInt8(ascii: "9")
    private static let asciiLowercaseA = UInt8(ascii: "a")
    private static let asciiLowercaseF = UInt8(ascii: "f")
    private static let asciiUppercaseA = UInt8(ascii: "A")
    private static let asciiUppercaseF = UInt8(ascii: "F")

    var isHexDigit: Bool {
        switch self {
        case (.asciiZero)...(.asciiNine),
            (.asciiLowercaseA)...(.asciiLowercaseF),
            (.asciiUppercaseA)...(.asciiUppercaseF):
            return true
        default:
            return false
        }
    }
}
