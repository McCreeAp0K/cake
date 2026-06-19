import Foundation
import ServiceManagement

/// 开机自启。用现代 `SMAppService.mainApp` 注册登录项。
///
/// 注意：仅当以 .app bundle 运行时有效（裸可执行无 bundle，注册会失败，安全忽略）。
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        setEnabled(!isEnabled)
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LoginItem 设置失败（可能未以 .app 运行）：\(error)")
        }
    }
}
