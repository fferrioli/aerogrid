import Foundation

public struct WindowManagerStatus: Codable, Equatable {
    public var enabled: Bool
    public var ready: Bool
    public init(enabled:Bool,ready:Bool) { self.enabled = enabled; self.ready = ready }
}
public struct WindowManagerPreferences: Codable {
    public var paused: Bool
    public init(paused:Bool = false) { self.paused = paused }
}
public protocol WindowManagerControl: AnyObject {
    func managementStatus() throws -> WindowManagerStatus
    func setManagementEnabled(_ enabled:Bool) throws
}
public enum WindowManagerSession {
    /// Acknowledge the real engine state before changing the frontend. A failed
    /// refresh/persistence restores the previous engine state, too.
    public static func setPaused(_ paused:Bool,backend:WindowManagerControl,afterChange:() throws -> Void = {}) throws {
        let before = try backend.managementStatus()
        guard before.ready else { throw GridError.unavailable("El servicio de ventanas todavía no está listo") }
        do {
            if before.enabled == paused { try backend.setManagementEnabled(!paused) }
            let actual = try backend.managementStatus()
            guard actual.ready, actual.enabled == !paused else { throw GridError.unavailable("No se pudo confirmar el estado de AeroGrid") }
            try afterChange()
        } catch {
            let failure = error
            do { try backend.setManagementEnabled(before.enabled) }
            catch { throw GridError.unavailable("No se pudo confirmar la pausa ni restaurar el servicio. Usá Recuperar.") }
            throw failure
        }
    }
}
