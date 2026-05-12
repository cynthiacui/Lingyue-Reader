import Foundation

/// Debug-only `print` shim. The `@autoclosure` ensures the message string
/// isn't even constructed in Release builds, so the diagnostic logs sprinkled
/// through import / discovery / browser flows have zero cost when distributed
/// to the App Store but stay available in Xcode debug sessions.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
