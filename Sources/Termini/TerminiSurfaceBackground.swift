/// Controls the native compositing background of a terminal surface.
///
/// This is separate from Ghostty's terminal appearance and renderer background
/// configuration so a host can remain transparent without changing terminal style state.
public enum TerminiSurfaceBackground: Hashable, Sendable {
    case terminal
    case transparent
}
