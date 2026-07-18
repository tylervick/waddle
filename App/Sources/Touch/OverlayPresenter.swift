import UIKit
import GameController
import WoofEngine

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
        let view = TouchOverlayView(gamepad: gamepad)
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        overlay = view

        pollTimer?.invalidate()
        pollTimer = nil

        applyPolicy()
    }

    private func registerNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPolicy()
        }
        center.addObserver(
            forName: NSNotification.Name.GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPolicy()
        }
        center.addObserver(
            forName: NSNotification.Name.GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPolicy()
        }
        center.addObserver(
            forName: NSNotification.Name.GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPolicy()
        }
    }

    private func unregisterNotificationObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSNotification.Name.GCControllerDidConnect, object: nil)
        center.removeObserver(self, name: NSNotification.Name.GCControllerDidDisconnect, object: nil)
        center.removeObserver(self, name: NSNotification.Name.GCKeyboardDidConnect, object: nil)
        center.removeObserver(self, name: NSNotification.Name.GCKeyboardDidDisconnect, object: nil)
    }

    private func applyPolicy() {
        let policy = PhysicalInputPolicy(
            controllerConnected: !GCController.controllers().isEmpty,
            hardwareKeyboardConnected: GCKeyboard.coalesced != nil
        )
        overlay?.isHidden = !policy.overlayShouldShow
    }
}
