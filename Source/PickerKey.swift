import Foundation

enum PickerKey: Equatable {
    case move(Int)
    case commit
    case cancel

    // Called only while the picker gesture is active. Outside it, keys pass through.
    static func action(for key: Int64) -> PickerKey? {
        switch key {
        case 125: return .move(1)
        case 126: return .move(-1)
        case 36, 76: return .commit
        case 53: return .cancel
        default: return nil
        }
    }
}

// Physical key codes, matching the event tap's existing shortcut handling.
enum SafariRefreshKey {
    static func shouldRefresh(_ key: Int64, command: Bool, control: Bool) -> Bool {
        // Return can submit the address bar; Ctrl-Tab/PageUp/PageDown can change tabs.
        if key == 36 || key == 76 { return true }
        if control && [Int64(48), 116, 121].contains(key) { return true }
        guard command else { return false }
        switch key {
        // T/W/N/R/L, brackets, backslash (overview), backtick (windows),
        // number keys (tab selection), and arrows (navigation).
        case 17, 13, 45, 15, 37, 33, 30, 42, 50,
             18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 123, 124:
            return true
        default:
            return false
        }
    }
}
