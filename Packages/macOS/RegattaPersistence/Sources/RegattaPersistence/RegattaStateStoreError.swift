public import Foundation

/// Errors thrown by ``RegattaStateStore``.
public enum RegattaStateStoreError: Error, Sendable {
    /// The on-disk state file could not be read or decoded. The associated value
    /// is the underlying error (file I/O or JSON decoding).
    case readFailed(any Error)
    /// The on-disk state file could not be written or encoded. The associated
    /// value is the underlying error (file I/O or JSON encoding).
    case writeFailed(any Error)
}
