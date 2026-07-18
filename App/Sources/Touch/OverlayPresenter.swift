import UIKit
import GameController
import WoofEngine

/// UserDefaults key for the Play tab's "Show Debug Info" toggle (LoadoutGridView's
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

    func begin() {
        end() // safety: never double-install
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
        // Read once at install time (matches the Play tab picker's
        // UserDefaults key); the overlay doesn't observe live changes mid-
        // session, only picks up a new scheme on the next install. Same
        // read-once-at-install policy for the debug HUD toggle and the
        // Control Feel tuning sliders — mid-session slider changes apply
        // to the next session.
        let scheme = TouchControlScheme.current()
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
        if ProcessInfo.processInfo.environment["BOOMBOX_FORCE_TOUCH_OVERLAY"] != nil {
            overlay?.isHidden = false
            return
        }

        let policy = PhysicalInputPolicy(
            controllerConnected: !GCController.controllers().isEmpty,
            hardwareKeyboardConnected: GCKeyboard.coalesced != nil
        )
        overlay?.isHidden = !policy.overlayShouldShow
    }
}
