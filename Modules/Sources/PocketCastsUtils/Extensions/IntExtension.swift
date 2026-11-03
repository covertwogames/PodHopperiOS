import Foundation

public extension Int {
    /// Converts like `Int(_:)`, dropping any fraction, but gives 0 instead of crashing when the value is NaN,
    /// infinite, or too large for an `Int`. Times and durations from players and feeds can be any of those.
    init(safeDouble: Double) {
        guard safeDouble.isFinite, let converted = Int(exactly: safeDouble.rounded(.towardZero)) else {
            self = 0
            return
        }

        self = converted
    }
}
