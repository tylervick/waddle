import UIKit

/// Sink for synthesized keystrokes. Abstracted so the character pump can be
/// unit-tested against a spy without the C engine bridge (TouchGamepad is
/// the production conformer, added in the integration task).
@MainActor
protocol TextInjecting: AnyObject {
    func injectCharacter(_ scalar: UnicodeScalar)
    func injectBackspace()
    func injectMenuConfirm()
}

/// Invisible UITextField used purely as a character funnel.
final class CheatTextField: UITextField {
    // No caret on an invisible funnel field.
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    // Suppress the copy/paste/select edit menu.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}

/// Owns the funnel text field + its delegate and turns keystrokes into
/// engine input via a TextInjecting sink. present()/dismiss() show and hide
/// the iOS system keyboard.
///
/// The field never accumulates text: a single non-breaking-space sentinel
/// is kept in it at all times, so the Delete key always produces a delegate
/// callback (an empty field would swallow it) -- letting us detect
/// backspaces via the delegate without overriding deleteBackward, and
/// giving the OS no prediction context. Every delegate change returns false,
/// so the sentinel stays put and nothing the user "types" is ever stored.
@MainActor
final class TouchKeyboard: NSObject, UITextFieldDelegate {
    private static let sentinel = "\u{00A0}" // non-breaking space

    let field = CheatTextField(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
    private let injector: TextInjecting
    private(set) var isVisible = false

    /// Invoked when Return is pressed; the overlay decides whether that
    /// means "commit save-name" or just "dismiss".
    var onReturn: (() -> Void)?

    /// Invoked when the field ends editing for a reason OTHER than our own
    /// dismiss() (system keyboard hide, focus steal) so the overlay can
    /// resync its control-lock state.
    var onExternalDismiss: (() -> Void)?
    private var dismissing = false

    init(injector: TextInjecting) {
        self.injector = injector
        super.init()
        field.delegate = self
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        if #available(iOS 17.0, *) { field.inlinePredictionType = .no }
        field.keyboardType = .asciiCapable
        field.keyboardAppearance = .dark
        field.tintColor = .clear
        field.text = Self.sentinel
    }

    @discardableResult
    func present() -> Bool {
        field.text = Self.sentinel
        isVisible = field.becomeFirstResponder()
        return isVisible
    }

    func dismiss() {
        dismissing = true
        field.resignFirstResponder()
        dismissing = false
        isVisible = false
    }

    // MARK: UITextFieldDelegate

    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        if string.isEmpty {
            injector.injectBackspace() // Delete key
        } else {
            for scalar in string.unicodeScalars where scalar.isASCII {
                injector.injectCharacter(scalar)
            }
        }
        return false // never accumulate; sentinel stays put
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        // Fires whenever the field loses first responder for ANY reason,
        // including the system hiding the keyboard or another responder
        // stealing focus. Resync so the overlay never sits with controls
        // disabled and no keyboard on screen. The `dismissing` guard skips
        // this for our own dismiss() path (which already resyncs).
        isVisible = false
        if !dismissing { onExternalDismiss?() }
    }
}
