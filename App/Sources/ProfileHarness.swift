import Foundation

#if DEBUG || WADDLE_PROFILE_HARNESS
/// Profiling seam (issue #246): lets `Scripts/profile-session.sh` launch
/// straight into an engine session playing a demo lump, with nobody touching
/// the phone, so a frame-time trace is of the same workload every run.
///
/// Sessions otherwise start only from a tap (`ShelfView.play`), and every
/// other argument seam is `#if DEBUG` (see `EngineSession.play`), which is
/// the wrong binary to profile. So this one is also compiled in under
/// `WADDLE_PROFILE_HARNESS`, a compilation condition only that script passes,
/// on a Release build it never archives. A shipping build defines neither
/// symbol and carries none of this; `Scripts/test-profile-session.sh` refuses
/// a tree where anything else sets the flag.
///
/// Three launch environment variables, the first two required:
/// - `WADDLE_PROFILE_GAME`: the shelf title to start ("Freedoom Phase 2").
/// - `WADDLE_PROFILE_DEMO`: the demo lump to play ("demo1").
/// - `WADDLE_PROFILE_MODE`: `playdemo` (default; real time, so the 35 Hz tic
///   and the uncapped renderer run as they do for a player) or `timedemo`
///   (one tic per frame, as fast as the device goes).
enum ProfileHarness {
    struct Request: Equatable {
        let gameName: String
        let engineArguments: [String]
    }

    /// The request the launch environment asks for, or nil. Anything
    /// malformed is nil rather than a guess: a profile of the wrong workload
    /// is worse than a launcher that visibly did nothing.
    static func request(environment: [String: String]) -> Request? {
        guard let game = environment["WADDLE_PROFILE_GAME"], !game.isEmpty,
              let demo = environment["WADDLE_PROFILE_DEMO"], isLumpName(demo)
        else { return nil }
        let mode = environment["WADDLE_PROFILE_MODE"] ?? "playdemo"
        guard mode == "playdemo" || mode == "timedemo" else { return nil }
        // -nogui: -timedemo ends in I_MessageBox, which would wait for a tap.
        return Request(gameName: game, engineArguments: ["-\(mode)", demo, "-nogui"])
    }

    /// A WAD lump name: 1-8 ASCII letters, digits or underscores. Keeps the
    /// seam from being a way to hand the engine an arbitrary argument.
    private static func isLumpName(_ name: String) -> Bool {
        (1...8).contains(name.utf8.count) && name.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
                || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F
        }
    }

    /// True once this launch has started its one profiled session.
    @MainActor static var started = false
}
#endif
