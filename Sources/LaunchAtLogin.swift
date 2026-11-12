import Foundation
import ServiceManagement

enum LaunchAtLogin {
 static let preferenceKey = "launchAtLogin.requested.v1"
 static var enabled: Bool { SMAppService.mainApp.status == .enabled }
 static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
 static var statusName: String {
  switch SMAppService.mainApp.status {
  case .enabled: return "enabled"
  case .requiresApproval: return "requiresApproval"
  case .notRegistered: return "notRegistered"
  case .notFound: return "notFound"
  @unknown default: return "unknown"
  }
 }
 static func setEnabled(_ value: Bool) throws {
  if value {
   if SMAppService.mainApp.status != .enabled && !needsApproval { try SMAppService.mainApp.register() }
  } else if SMAppService.mainApp.status != .notRegistered {
   try SMAppService.mainApp.unregister()
  }
  UserDefaults.standard.set(value, forKey: preferenceKey)
 }
 // Enable once on upgrade/first launch. A later user opt-out, including one
 // made in System Settings, must never be silently reversed on every launch.
 static func configureIfNeeded() throws {
  guard UserDefaults.standard.object(forKey: preferenceKey) == nil else { return }
  try setEnabled(true)
 }
}
