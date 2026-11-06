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
