import Foundation
#if canImport(PassKit)
import PassKit
#endif

/// What a host app may ask the iPhone My Number card (Apple Wallet) for.
///
/// There is deliberately no case for the individual number (My Number). Private
/// businesses may collect it only for tax and social security procedures, so an
/// identity verification SDK has no reason to offer it.
public enum WalletIDElement: Hashable, Sendable {
    case name
    case address
    case dateOfBirth
    case sex
    case portrait
    /// Only whether the holder is at least this old, without the birth date.
    case ageAtLeast(Int)
}

/// The encrypted response from Wallet. The kit never decrypts it.
public struct WalletIDPresentation: Equatable, Sendable {
    /// An ISO/IEC 18013-5 response encrypted to the host's merchant key. Only the host's server can open it.
    public let encryptedData: Data
    /// The nonce the request carried. The server checks the decrypted response against it.
    public let nonce: Data
}

public enum WalletIDAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    public enum Reason: Equatable, Sendable {
        /// Wallet cannot answer this request here: no My Number card in Wallet, an unsupported
        /// device or region, or an app without the identity entitlement.
        case cannotRequest
    }
}

/// Why a Wallet request did not produce a presentation. Every case says what the host app can do next.
public enum WalletIDError: Error, Equatable, Sendable {
    /// Show another way to verify, such as reading the card over NFC.
    case unavailable(WalletIDAvailability.Reason)
    /// The person closed the Wallet sheet. Treat it as a normal exit.
    case cancelled
    /// Wallet needs the network. Ask the person to retry when online.
    case networkUnavailable
    /// The nonce from the server was empty or too long. A server bug, not the person's.
    case invalidNonce
    /// The request asked for nothing, or for an element Wallet rejects. A host app bug.
    case invalidRequest
    /// Another Wallet request is still open. Wait for it to finish.
    case busy
    /// Wallet does not support this document region here.
    case regionNotSupported
    /// PassKit reported an error the kit does not map. The code is PKIdentityError.Code.
    case system(code: Int)
}

/// Everything a Wallet request carries, independent of PassKit so it can be tested.
struct WalletIDRequestSpec: Equatable, Sendable {
    static let region = "JP"
    /// The kit's own bounds: long enough to be unguessable, short enough for Wallet to accept.
    static let nonceLength = 16...64

    let elements: [WalletIDElement]
    let storeForDays: Int?
    let nonce: Data
    let merchantIdentifier: String

    init(elements: Set<WalletIDElement>, storeForDays: Int?, nonce: Data, merchantIdentifier: String) throws(WalletIDError) {
        guard !elements.isEmpty, storeForDays.map({ $0 > 0 }) ?? true else { throw .invalidRequest }
        guard Self.nonceLength.contains(nonce.count) else { throw .invalidNonce }
        // A stable order, so the same request always looks the same.
        self.elements = elements.sorted { String(describing: $0) < String(describing: $1) }
        self.storeForDays = storeForDays
        self.nonce = nonce
        self.merchantIdentifier = merchantIdentifier
    }
}

/// Asks Wallet. PassKit is one implementation; tests use another.
protocol IdentityAuthorizing: Sendable {
    func canRequest(_ spec: WalletIDRequestSpec) async -> Bool
    /// Returns the encrypted response, or throws an error in PKIdentityErrorDomain.
    func request(_ spec: WalletIDRequestSpec) async throws -> Data
}

/// Requests identity data from the iPhone My Number card in Apple Wallet.
///
/// The kit builds the request and hands the encrypted response to the host app,
/// which sends it to its server. Decrypting it, checking the issuer's signature,
/// the device signature and the nonce all happen on the server. Using it needs
/// Apple's in-app identity presentment entitlement for the app's bundle ID and,
/// for the My Number card, the Digital Agency's approval of the service.
@available(iOS 18.0, *)
public struct WalletIDReader: Sendable {
    let merchantIdentifier: String
    let authorizer: any IdentityAuthorizing

    public init(merchantIdentifier: String) {
        #if canImport(PassKit) && os(iOS)
        self.init(merchantIdentifier: merchantIdentifier, authorizer: PassKitIdentityAuthorizer())
        #else
        self.init(merchantIdentifier: merchantIdentifier, authorizer: UnavailableIdentityAuthorizer())
        #endif
    }

    init(merchantIdentifier: String, authorizer: any IdentityAuthorizing) {
        self.merchantIdentifier = merchantIdentifier
        self.authorizer = authorizer
    }

    /// Whether Wallet can answer a request for these elements right now. Check before showing the button.
    public func availability(for elements: Set<WalletIDElement>) async -> WalletIDAvailability {
        let probe = Data(repeating: 0, count: WalletIDRequestSpec.nonceLength.lowerBound)
        guard let spec = try? WalletIDRequestSpec(
            elements: elements, storeForDays: nil, nonce: probe, merchantIdentifier: merchantIdentifier)
        else { return .unavailable(.cannotRequest) }
        return await authorizer.canRequest(spec) ? .available : .unavailable(.cannotRequest)
    }

    /// Shows the Wallet sheet and returns the encrypted response.
    ///
    /// - Parameters:
    ///   - elements: Ask for the least the service needs. Prefer `.ageAtLeast` to `.dateOfBirth`.
    ///   - nonce: A fresh value from the host's server, 16 to 64 bytes, used once.
    ///   - storeForDays: How long the service keeps the data, shown to the person. nil means it will not store it.
    public func requestPresentation(
        of elements: Set<WalletIDElement>, nonce: Data, storeForDays: Int? = nil
    ) async throws(WalletIDError) -> WalletIDPresentation {
        let spec = try WalletIDRequestSpec(
            elements: elements, storeForDays: storeForDays, nonce: nonce, merchantIdentifier: merchantIdentifier)
        do {
            return WalletIDPresentation(encryptedData: try await authorizer.request(spec), nonce: nonce)
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: any Error) -> WalletIDError {
        if let error = error as? WalletIDError { return error }
        let error = error as NSError
        #if canImport(PassKit) && os(iOS)
        guard error.domain == PKIdentityErrorDomain else { return .system(code: error.code) }
        switch PKIdentityError.Code(rawValue: error.code) {
        case .notSupported: return .unavailable(.cannotRequest)
        case .cancelled: return .cancelled
        case .networkUnavailable: return .networkUnavailable
        case .noElementsRequested, .invalidElement: return .invalidRequest
        case .requestAlreadyInProgress: return .busy
        case .invalidNonce: return .invalidNonce
        case .regionNotSupported: return .regionNotSupported
        default: return .system(code: error.code)
        }
        #else
        return .system(code: error.code)
        #endif
    }
}

struct UnavailableIdentityAuthorizer: IdentityAuthorizing {
    func canRequest(_ spec: WalletIDRequestSpec) async -> Bool { false }
    func request(_ spec: WalletIDRequestSpec) async throws -> Data { throw WalletIDError.unavailable(.cannotRequest) }
}

#if canImport(PassKit) && os(iOS)
/// Talks to Apple Wallet through PassKit. A controller is made per call and used only on the main actor.
@available(iOS 18.0, *)
struct PassKitIdentityAuthorizer: IdentityAuthorizing {
    @MainActor
    func canRequest(_ spec: WalletIDRequestSpec) async -> Bool {
        await PKIdentityAuthorizationController().canRequestDocument(Self.descriptor(for: spec))
    }

    @MainActor
    func request(_ spec: WalletIDRequestSpec) async throws -> Data {
        try await PKIdentityAuthorizationController().requestDocument(Self.request(for: spec)).encryptedData
    }

    static func descriptor(for spec: WalletIDRequestSpec) -> PKIdentityNationalIDCardDescriptor {
        let descriptor = PKIdentityNationalIDCardDescriptor()
        descriptor.region = Locale.Region(WalletIDRequestSpec.region)
        let intent: PKIdentityIntentToStore = spec.storeForDays.map { .mayStore(days: $0) } ?? .willNotStore
        descriptor.addElements(spec.elements.flatMap(Self.elements(for:)), intentToStore: intent)
        return descriptor
    }

    static func request(for spec: WalletIDRequestSpec) -> PKIdentityRequest {
        let request = PKIdentityRequest()
        request.descriptor = descriptor(for: spec)
        request.nonce = spec.nonce
        request.merchantIdentifier = spec.merchantIdentifier
        return request
    }

    static func elements(for element: WalletIDElement) -> [PKIdentityElement] {
        switch element {
        case .name: [.givenName, .familyName]
        case .address: [.address]
        case .dateOfBirth: [.dateOfBirth]
        case .sex: [.sex]
        case .portrait: [.portrait]
        case .ageAtLeast(let age): [.age(atLeast: age)]
        }
    }
}
#endif
