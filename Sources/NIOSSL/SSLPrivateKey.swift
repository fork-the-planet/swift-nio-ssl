//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if compiler(>=6.1)
internal import CNIOBoringSSL
#else
@_implementationOnly import CNIOBoringSSL
#endif

/// An ``NIOSSLPassphraseCallback`` is a callback that will be invoked by NIOSSL when it needs to
/// get access to a private key that is stored in encrypted form.
///
/// This callback will be invoked with one argument, a non-escaping closure that must be called with the
/// passphrase. Failing to call the closure will cause decryption to fail.
///
/// The reason this design has been used is to allow you to secure any memory storing the passphrase after
/// use. We guarantee that after the ``NIOSSLPassphraseSetter`` closure has been invoked the `Collection`
/// you have passed in will no longer be needed by BoringSSL, and so you can safely destroy any memory it
/// may be using if you need to.
public typealias NIOSSLPassphraseCallback<Bytes: Collection> = (NIOSSLPassphraseSetter<Bytes>) throws -> Void
where Bytes.Element == UInt8

/// An ``NIOSSLPassphraseSetter`` is a closure that you must invoke to provide a passphrase to BoringSSL.
/// It will be provided to you when your ``NIOSSLPassphraseCallback`` is invoked.
public typealias NIOSSLPassphraseSetter<Bytes: Collection> = (Bytes) -> Void where Bytes.Element == UInt8

/// An internal protocol that exists to let us avoid problems with generic types.
///
/// The issue we have here is that we want to allow users to use whatever collection type suits them best to set
/// the passphrase. For this reason, ``NIOSSLPassphraseSetter`` is a generic function, generic over the `Collection`
/// protocol. However, that causes us an issue, because we need to stuff that callback into an
/// ``BoringSSLPassphraseCallbackManager`` in order to create an `Unmanaged` and round-trip the pointer through C code.
///
/// That makes ``BoringSSLPassphraseCallbackManager`` a generic object, and now we're in *real* trouble, becuase
/// `Unmanaged` requires us to specify the *complete* type of the object we want to unwrap. In this case, we
/// don't know it, because it's generic!
///
/// Our way out is to note that while the class itself is generic, the only function we want to call in the
/// ``globalBoringSSLPassphraseCallback`` is not. Thus, rather than try to hold the actual specific ``BoringSSLPassphraseManager``,
/// we can hold it inside a protocol existential instead, so long as that protocol existential gives us the correct
/// function to call. Hence: ``CallbackManagerProtocol``, a private protocol with a single conforming type.
internal protocol CallbackManagerProtocol: AnyObject {
    func invoke(buffer: UnsafeMutableBufferPointer<CChar>) -> CInt
}

/// This class exists primarily to work around the fact that Swift does not let us stuff
/// a closure into an `Unmanaged`. Instead, we use this object to keep hold of it.
final class BoringSSLPassphraseCallbackManager<Bytes: Collection>: CallbackManagerProtocol
where Bytes.Element == UInt8 {
    private let userCallback: NIOSSLPassphraseCallback<Bytes>

    init(userCallback: @escaping NIOSSLPassphraseCallback<Bytes>) {
        // We have to type-erase this.
        self.userCallback = userCallback
    }

    func invoke(buffer: UnsafeMutableBufferPointer<CChar>) -> CInt {
        var count: CInt = 0

        do {
            try self.userCallback { passphraseBytes in
                // If we don't have enough space for the passphrase plus NUL, bail out.
                guard passphraseBytes.count < buffer.count else { return }
                _ = buffer.initialize(from: passphraseBytes.lazy.map { CChar($0) })
                count = CInt(passphraseBytes.count)

                // We need to add a NUL terminator, in case the user did not.
                buffer[Int(passphraseBytes.count)] = 0
            }
        } catch {
            // If we hit an error here, we just need to tolerate it. We'll return zero-length.
            count = 0
        }

        return count
    }
}

/// Our global static BoringSSL passphrase callback. This is used as a thunk to dispatch out to
/// the user-provided callback.
func globalBoringSSLPassphraseCallback(
    buf: UnsafeMutablePointer<CChar>?,
    size: CInt,
    rwflag: CInt,
    u: UnsafeMutableRawPointer?
) -> CInt {
    guard let buffer = buf, let userData = u else {
        preconditionFailure(
            "Invalid pointers passed to passphrase callback, buf: \(String(describing: buf)) u: \(String(describing: u))"
        )
    }
    let bufferPointer = UnsafeMutableBufferPointer(start: buffer, count: Int(size))
    guard let cbManager = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue() as? CallbackManagerProtocol
    else {
        preconditionFailure("Failed to pass object that can handle callback")
    }
    return cbManager.invoke(buffer: bufferPointer)
}

/// A reference to an BoringSSL private key object in the form of an `EVP_PKEY *`.
///
/// This thin wrapper class allows us to use ARC to automatically manage
/// the memory associated with this key. That ensures that BoringSSL
/// will not free the underlying buffer until we are done with the key.
///
/// This class also provides several convenience constructors that allow users
/// to obtain an in-memory representation of a key from a buffer of
/// bytes or from a file path.
public final class NIOSSLPrivateKey {
    @usableFromInline
    internal enum Representation {
        case native(OpaquePointer)  // <EVP_PKEY>
        case custom(AnyNIOSSLCustomPrivateKey)
    }

    @usableFromInline
    internal let representation: Representation

    internal func withUnsafeMutableEVPPKEYPointer<ReturnType>(
        _ body: (OpaquePointer) throws -> ReturnType
    ) rethrows -> ReturnType {
        guard case .native(let pointer) = self.representation else {
            preconditionFailure()
        }

        return try body(pointer)
    }

    private init(withReference ref: OpaquePointer) {
        self.representation = .native(ref)
    }

    /// A delegating initializer for `init(file:format:passphraseCallback)` and `init(file:format:)`.
    private convenience init(
        file: String,
        format: NIOSSLSerializationFormats,
        callbackManager: CallbackManagerProtocol?
    ) throws {
        let fileObject = try Posix.fopen(file: file, mode: "rb")
        defer {
            // If fclose fails there is nothing we can do about it.
            _ = try? Posix.fclose(file: fileObject)
        }

        let key = withExtendedLifetime(callbackManager) { callbackManager -> OpaquePointer? in
            guard let bio = CNIOBoringSSL_BIO_new_fp(fileObject, BIO_NOCLOSE) else {
                return nil
            }
            defer {
                CNIOBoringSSL_BIO_free(bio)
            }

            switch format {
            case .pem:
                // This annoying conditional binding is used to work around the fact that I cannot pass
                // a variable to a function pointer argument.
                if let callbackManager = callbackManager {
                    return CNIOBoringSSL_PEM_read_PrivateKey(
                        fileObject,
                        nil,
                        { globalBoringSSLPassphraseCallback(buf: $0, size: $1, rwflag: $2, u: $3) },
                        Unmanaged.passUnretained(callbackManager as AnyObject).toOpaque()
                    )
                } else {
                    return CNIOBoringSSL_PEM_read_PrivateKey(fileObject, nil, nil, nil)
                }
            case .der:
                return CNIOBoringSSL_d2i_PrivateKey_fp(fileObject, nil)
            }
        }

        if key == nil {
            throw NIOSSLError.failedToLoadPrivateKey
        }

        self.init(withReference: key!)
    }

    /// A delegating initializer for `init(buffer:format:passphraseCallback)` and `init(buffer:format:)`.
    private convenience init(
        bytes: [UInt8],
        format: NIOSSLSerializationFormats,
        callbackManager: CallbackManagerProtocol?
    ) throws {
        let ref = bytes.withUnsafeBytes { (ptr) -> OpaquePointer? in
            let bio = CNIOBoringSSL_BIO_new_mem_buf(ptr.baseAddress!, ptr.count)!
            defer {
                CNIOBoringSSL_BIO_free(bio)
            }

            return withExtendedLifetime(callbackManager) { callbackManager -> OpaquePointer? in
                switch format {
                case .pem:
                    if let callbackManager = callbackManager {
                        // This annoying conditional binding is used to work around the fact that I cannot pass
                        // a variable to a function pointer argument.
                        return CNIOBoringSSL_PEM_read_bio_PrivateKey(
                            bio,
                            nil,
                            { globalBoringSSLPassphraseCallback(buf: $0, size: $1, rwflag: $2, u: $3) },
                            Unmanaged.passUnretained(callbackManager as AnyObject).toOpaque()
                        )
                    } else {
                        return CNIOBoringSSL_PEM_read_bio_PrivateKey(bio, nil, nil, nil)
                    }
                case .der:
                    return CNIOBoringSSL_d2i_PrivateKey_bio(bio, nil)
                }
            }
        }

        if ref == nil {
            throw NIOSSLError.failedToLoadPrivateKey
        }

        self.init(withReference: ref!)
    }

    /// Create a ``NIOSSLPrivateKey`` from a file at a given path in either PEM or
    /// DER format, providing a passphrase callback.
    ///
    /// - parameters:
    ///     - file: The path to the file to load.
    ///     - format: The format of the key to load, either DER or PEM.
    public convenience init(file: String, format: NIOSSLSerializationFormats) throws {
        try self.init(file: file, format: format, callbackManager: nil)
    }

    /// Create a ``NIOSSLPrivateKey`` from a file at a given path in either PEM or
    /// DER format, providing a passphrase callback.
    ///
    /// - parameters:
    ///     - file: The path to the file to load.
    ///     - format: The format of the key to load, either DER or PEM.
    ///     - passphraseCallback: A callback to invoke to obtain the passphrase for
    ///         encrypted keys.
    public convenience init<T: Collection>(
        file: String,
        format: NIOSSLSerializationFormats,
        passphraseCallback: @escaping NIOSSLPassphraseCallback<T>
    ) throws where T.Element == UInt8 {
        let manager = BoringSSLPassphraseCallbackManager(userCallback: passphraseCallback)
        try self.init(file: file, format: format, callbackManager: manager)
    }

    /// Create a ``NIOSSLPrivateKey`` from a buffer of bytes in either PEM or
    /// DER format.
    ///
    /// - parameters:
    ///     - buffer: The key bytes.
    ///     - format: The format of the key to load, either DER or PEM.
    /// - SeeAlso: ``NIOSSLPrivateKey/init(bytes:format:)``
    @available(*, deprecated, renamed: "NIOSSLPrivateKey.init(bytes:format:)")
    public convenience init(buffer: [Int8], format: NIOSSLSerializationFormats) throws {
        try self.init(bytes: buffer.map(UInt8.init), format: format)
    }

    /// Create a ``NIOSSLPrivateKey`` from a buffer of bytes in either PEM or
    /// DER format.
    ///
    /// - parameters:
    ///     - bytes: The key bytes.
    ///     - format: The format of the key to load, either DER or PEM.
    public convenience init(bytes: [UInt8], format: NIOSSLSerializationFormats) throws {
        try self.init(bytes: bytes, format: format, callbackManager: nil)
    }

    /// Create a ``NIOSSLPrivateKey`` from a buffer of bytes in either PEM or
    /// DER format.
    ///
    /// - parameters:
    ///     - buffer: The key bytes.
    ///     - format: The format of the key to load, either DER or PEM.
    ///     - passphraseCallback: Optionally a callback to invoke to obtain the passphrase for
    ///         encrypted keys. If not provided, or set to `nil`, the default BoringSSL
    ///         behaviour will be used, which prints a prompt and requests the passphrase from
    ///         stdin.
    /// - SeeAlso: `NIOSSLPrivateKey.init(bytes:format:passphraseCallback:)`
    @available(*, deprecated, renamed: "NIOSSLPrivateKey.init(bytes:format:passphraseCallback:)")
    public convenience init<T: Collection>(
        buffer: [Int8],
        format: NIOSSLSerializationFormats,
        passphraseCallback: @escaping NIOSSLPassphraseCallback<T>
    ) throws where T.Element == UInt8 {
        try self.init(bytes: buffer.map(UInt8.init), format: format, passphraseCallback: passphraseCallback)
    }

    /// Create a ``NIOSSLPrivateKey`` from a buffer of bytes in either PEM or
    /// DER format.
    ///
    /// - parameters:
    ///     - bytes: The key bytes.
    ///     - format: The format of the key to load, either DER or PEM.
    ///     - passphraseCallback: Optionally a callback to invoke to obtain the passphrase for
    ///         encrypted keys. If not provided, or set to `nil`, the default BoringSSL
    ///         behaviour will be used, which prints a prompt and requests the passphrase from
    ///         stdin.
    public convenience init<T: Collection>(
        bytes: [UInt8],
        format: NIOSSLSerializationFormats,
        passphraseCallback: @escaping NIOSSLPassphraseCallback<T>
    ) throws where T.Element == UInt8 {
        let manager = BoringSSLPassphraseCallbackManager(userCallback: passphraseCallback)
        try self.init(bytes: bytes, format: format, callbackManager: manager)
    }

    /// Create a ``NIOSSLPrivateKey`` from a custom private key callback.
    ///
    /// The private key, in addition to needing to conform to ``NIOSSLCustomPrivateKey``,
    /// is also required to be `Hashable`. This is because ``NIOSSLPrivateKey``s are `Hashable`.
    ///
    /// - parameters:
    ///     - customPrivateKey: The custom private key to use with the TLS certificate.
    @inlinable
    public init<CustomKey: NIOSSLCustomPrivateKey & Hashable>(customPrivateKey: CustomKey) {
        self.representation = .custom(AnyNIOSSLCustomPrivateKey(customPrivateKey))
    }

    /// Create an NIOSSLPrivateKey wrapping a pointer into BoringSSL.
    ///
    /// This is a function that should be avoided as much as possible because it plays poorly with
    /// BoringSSL's reference-counted memory. This function does not increment the reference count for the EVP_PKEY
    /// object here, nor does it duplicate it: it just takes ownership of the copy here. This object
    /// **will** deallocate the underlying EVP_PKEY object when deinited, and so if you need to keep that
    /// EVP_PKEY object alive you create a new EVP_PKEY before passing that object here.
    ///
    /// In general, however, this function should be avoided in favour of one of the convenience
    /// initializers, which ensure that the lifetime of the EVP_PKEY object is better-managed.
    static internal func fromUnsafePointer(takingOwnership pointer: OpaquePointer) -> NIOSSLPrivateKey {
        NIOSSLPrivateKey(withReference: pointer)
    }

    deinit {
        switch self.representation {
        case .native(let ref):
            CNIOBoringSSL_EVP_PKEY_free(ref)
        case .custom:
            // Merely dropping the ref is enough.
            ()
        }
    }
}

// NIOSSLPrivateKey is publicly immutable and we do not internally mutate it after initialisation.
// It is therefore Sendable.
extension NIOSSLPrivateKey: @unchecked Sendable {}

// MARK:- Utilities
extension NIOSSLPrivateKey {
    /// Calls the given body function with a temporary buffer containing the DER-encoded bytes of this
    /// private key. This function does allocate for these bytes, but there is no way to avoid doing so with the
    /// X509 API in BoringSSL.
    ///
    /// The pointer provided to the closure is not valid beyond the lifetime of this method call.
    ///
    /// This method is only safe to call on native private keys.
    private static func withUnsafeDERBuffer<T>(
        of ref: OpaquePointer,
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) throws -> T {
        guard let bio = CNIOBoringSSL_BIO_new(CNIOBoringSSL_BIO_s_mem()) else {
            fatalError("Failed to malloc for a BIO handler")
        }

        defer {
            CNIOBoringSSL_BIO_free(bio)
        }

        let rc = CNIOBoringSSL_i2d_PrivateKey_bio(bio, ref)
        guard rc == 1 else {
            let errorStack = BoringSSLError.buildErrorStack()
            throw BoringSSLError.unknownError(errorStack)
        }

        var dataPtr: UnsafeMutablePointer<CChar>? = nil
        let length = CNIOBoringSSL_BIO_get_mem_data(bio, &dataPtr)

        guard let bytes = dataPtr.map({ UnsafeRawBufferPointer(start: $0, count: length) }) else {
            fatalError("Failed to map bytes from a private key")
        }

        return try body(bytes)
    }

    /// The custom signing algorithms required by this private key, if any.
    ///
    /// Is `nil` when the key is a native key, as this is handled by BoringSSL.
    internal var customSigningAlgorithms: [SignatureAlgorithm]? {
        switch self.representation {
        case .native:
            return nil
        case .custom(let customKey):
            return customKey.signatureAlgorithms
        }
    }

    /// Extracts the bytes of this private key in DER format.
    /// - Returns: The DER-encoded bytes for this private key.
    public var derBytes: [UInt8] {
        get throws {
            switch self.representation {
            case .native(let evpKey):
                return try Self.withUnsafeDERBuffer(of: evpKey) { Array($0) }
            case .custom(let custom):
                return custom.derBytes
            }
        }
    }
}

extension NIOSSLPrivateKey: Equatable {
    public static func == (lhs: NIOSSLPrivateKey, rhs: NIOSSLPrivateKey) -> Bool {
        switch (lhs.representation, rhs.representation) {
        case (.native, .native):
            // Annoyingly, EVP_PKEY_cmp does not have a traditional return value pattern. 1 means equal, 0 means non-equal,
            // negative means error. Here we treat "error" as "not equal", because we have no error reporting mechanism from this call site,
            // and anyway, BoringSSL considers "these keys aren't of the same type" to be an error, which is in my mind pretty ludicrous.
            return lhs.withUnsafeMutableEVPPKEYPointer { lhsRef in
                rhs.withUnsafeMutableEVPPKEYPointer { rhsRef in
                    CNIOBoringSSL_EVP_PKEY_cmp(lhsRef, rhsRef) == 1
                }
            }

        case (.custom(let lhsCustom), .custom(let rhsCustom)):
            return lhsCustom == rhsCustom

        case (.native, .custom), (.custom, .native):
            return false
        }
    }
}

extension NIOSSLPrivateKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self.representation {
        case .native(let ref):
            // Sadly, BoringSSL doesn't provide us with a nice key hashing function. We therefore have only two options:
            // we can either serialize the key into DER and feed that into the hasher, or we can attempt to hash the key parameters directly.
            // We could attempt the latter, but frankly it causes a lot of pain for minimal gain, so we don't bother. This incurs an allocation,
            // but that's ok. We crash if we hit an error here, as there is no way to recover.
            hasher.combine(0)
            try! NIOSSLPrivateKey.withUnsafeDERBuffer(of: ref) { hasher.combine(bytes: $0) }
        case .custom(let custom):
            hasher.combine(1)
            custom.hash(into: &hasher)
        }
    }
}

@available(*, unavailable)
extension NIOSSLPrivateKey.Representation: Sendable {}
