import UIKit
import GameController
import WoofEngine

/// UserDefaults key for the "Show Debug Info" toggle (PlayerSettingsView's
/// @AppStorage("debugHUD")): gates both the launcher's build-info footer and
/// the in-session debug HUD this file reads at install time, below.
let debugHUDUserDefaultsKey = "debugHUD"

struct PhysicalInputPolicy: Equatable {
    var controllerConnected: Bool
    var hardwareKeyboardConnected: Bool
    var overlayShouldShow: Bool { !controllerConnected && !hardwareKeyboardConnected }
}

/// Installs the touch overlay into SDL's UIWindow once the engine session
/// creates it, and removes it when the session ends. Works because SDL pumps
/// the main run loop during sessions, so our Timer keeps firing while
/// WoofIOS_Run blocks.
@MainActor
final class OverlayPresenter {
    static let shared = OverlayPresenter()

    private let gamepad = TouchGamepad()
    private var overlay: TouchOverlayView?
    private var pollTimer: Timer?
    private var observerTokens: [NSObjectProtocol] = []
    /// The scheme to install with, supplied by `begin(scheme:)` — replaces the
    /// old read-at-install of `TouchControlScheme.current()` so a per-item
    /// override can flow in from the launch site.
    private var installScheme: TouchControlScheme = TouchControlScheme.defaultScheme

    #if DEBUG
    var installSchemeForTesting: TouchControlScheme { installScheme }
    #endif

    func begin(scheme: TouchControlScheme) {
        end() // safety: never double-install
        installScheme = scheme
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryInstall() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        registerNotificationObservers()
    }

    func end() {
        pollTimer?.invalidate()
        pollTimer = nil
        overlay?.removeFromSuperview()
        overlay = nil
        gamepad.detach()

        unregisterNotificationObservers()
    }

    private func tryInstall() {
        guard overlay == nil,
              let pointer = WoofIOS_GetUIWindowPointer()
        else { return }

        // Attach the virtual gamepad first; retries until SDL's joystick
        // subsystem is up. Don't install the overlay before input works.
        guard gamepad.attachIfPossible() else { return }

        let window = Unmanaged<UIWindow>.fromOpaque(pointer)
            .takeUnretainedValue()
        // Scheme was fixed at begin(scheme:) time -- supplied by the launch
        // site via EngineSession.play and stored in installScheme -- not
        // read from UserDefaults here. Same read-once-at-install policy
        // applies to the tuning and the debug HUD toggle read below:
        // mid-session changes apply to the next session, not this one.
        let scheme = installScheme
        let tuning = TouchTuning.current()
        gamepad.tuning = tuning
        let debugHUDEnabled = UserDefaults.standard.bool(forKey: debugHUDUserDefaultsKey)
        let view = TouchOverlayView(gamepad: gamepad, scheme: scheme,
                                    tuning: tuning, debugHUDEnabled: debugHUDEnabled)
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        overlay = view

        pollTimer?.invalidate()
        pollTimer = nil

        applyPolicy()
    }

    private func registerNotificationObservers() {
        // Guard against double-registration: if already registered, return early
        guard observerTokens.isEmpty else { return }

        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(
                forName: NSNotification.Name.GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyPolicy()
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: NSNotification.Name.GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyPolicy()
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyPolicy()
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyPolicy()
            }
        )
    }

    private func unregisterNotificationObservers() {
        let center = NotificationCenter.default
        observerTokens.forEach { center.removeObserver($0) }
        observerTokens.removeAll()
    }

    /// True when a harness flag asks for the overlay to stay visible whatever
    /// physical input is attached. Two hatches, because the two harnesses
    /// inject differently:
    ///
    /// - `WADDLE_FORCE_TOUCH_OVERLAY` is a launch environment variable, set by
    ///   XCUITest through `app.launchEnvironment` (see `applyPolicy()` below
    ///   for why the simulator needs it at all).
    /// - `WADDLE_PROOF_HARNESS` is a compilation condition, for Revyl's
    ///   proof-of-changes runs. Those drive an already-installed app and have
    ///   no launch environment to set, and `.revyl/config.yaml` accepts no
    ///   launch-variable field at any level -- probed across every name and
    ///   nesting the contract has, see
    ///   docs/learnings/revyl-proof-cannot-set-launch-env.md. The build is
    ///   therefore the only injection point we control, so
    ///   `build_commands` there passes this via
    ///   SWIFT_ACTIVE_COMPILATION_CONDITIONS. It is never defined for a
    ///   developer Debug build and cannot be reached in Release.
    ///
    /// `Scripts/check-proof-harness-flag.sh` keeps this symbol and the
    /// `.revyl/config.yaml` setter from drifting apart.
    private var overlayForcedVisibleByHarness: Bool {
        #if WADDLE_PROOF_HARNESS
        return true
        #elseif DEBUG
        return ProcessInfo.processInfo.environment["WADDLE_FORCE_TOUCH_OVERLAY"] != nil
        #else
        return false
        #endif
    }

    private func applyPolicy() {
        // Test-only escape hatch (Plan 3 Task 6): under the iOS Simulator's
        // XCUITest automation session, GameController reports a phantom
        // GCController *and* GCKeyboard.coalesced as connected (the host
        // Mac's own keyboard, plus something about the automation session
        // itself) for the whole session -- confirmed via diagnostic
        // logging, not the simulator-keyboard flakiness Task 5 anticipated.
        // That's correct, unit-tested production behavior
        // (PhysicalInputPolicyTests) firing on a false positive in this one
        // harness, which made the touch overlay permanently inaccessible to
        // XCUITest -- TouchControlsTests couldn't verify install, input, or
        // teardown at all. Only ever set by the UI test; never present in a
        // real session.
        let shown: Bool
        var controllerConnected = false
        if overlayForcedVisibleByHarness {
            shown = true
        } else {
            let policy = PhysicalInputPolicy(
                controllerConnected: !GCController.controllers().isEmpty,
                hardwareKeyboardConnected: GCKeyboard.coalesced != nil
            )
            shown = policy.overlayShouldShow
            controllerConnected = policy.controllerConnected
        }
        overlay?.isHidden = !shown
        // A visible overlay is the input the player has, forced or not; make
        // the engine read its stick from our pad rather than from whatever
        // MFi controller it opened first -- the same phantom controller the
        // comment above describes is what the engine picks up, and Revyl's
        // farm devices present one too. The engine keeps whichever gamepad
        // it opened first, so the converse needs saying too: when a physical
        // controller is what hid the overlay, hand the engine that
        // controller, or a pad that connected after ours would never be
        // read. A keyboard-only hide changes nothing; our pad stays
        // attached either way so it can take input back when the
        // controller goes.
        if shown {
            gamepad.selectAsEngineInput()
        } else if controllerConnected {
            gamepad.yieldToPhysicalController()
        }
    }
}
