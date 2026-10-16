import Foundation
import LocalAuthentication
import Security
import CryptoKit

enum Keychain {
    private static let service = "dev.scyde.inutt"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

@MainActor
final class LockManager: ObservableObject {
    static let shared = LockManager()

    @Published private(set) var isLocked: Bool
    @Published var isAuthenticating = false

    private init() {
        let s = AppSettings.shared
        isLocked = s.faceIDEnabled || (s.pinEnabled && Keychain.get("pin") != nil)
    }

    var hasPIN: Bool { Keychain.get("pin") != nil }

    var isProtectionOn: Bool {
        let s = AppSettings.shared
        return s.faceIDEnabled || (s.pinEnabled && hasPIN)
    }

    static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        default: return "Face ID"
        }
    }

    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func lockIfNeeded() {
        if isProtectionOn && AppSettings.shared.lockOnBackground { isLocked = true }
    }

    func unlock() { isLocked = false }

    func authenticateBiometric() async {
        guard AppSettings.shared.faceIDEnabled, !isAuthenticating else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = hasPIN && AppSettings.shared.pinEnabled ? "Enter PIN" : ""
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock iNUTT")) ?? false
        if ok { isLocked = false }
    }

    /// Fallback when Face ID is on but no PIN is set: use the device passcode.
    func authenticateDevice() async {
        let ctx = LAContext()
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock iNUTT")) ?? false
        if ok { isLocked = false }
    }

    func verify(_ pin: String) -> Bool {
        guard let stored = Keychain.get("pin") else { return false }
        let ok = stored == Self.hash(pin)
        if ok { isLocked = false }
        return ok
    }

    var pinLength: Int { max(4, UserDefaults.standard.integer(forKey: "pinLength")) }

    func setPIN(_ pin: String?) {
        Keychain.set(pin.map(Self.hash), for: "pin")
        UserDefaults.standard.set(pin?.count ?? 0, forKey: "pinLength")
        AppSettings.shared.pinEnabled = pin != nil
    }

    static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data(("inutt-salt-" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
