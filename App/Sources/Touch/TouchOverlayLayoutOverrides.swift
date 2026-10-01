import CoreGraphics
import Foundation

/// Where the player put each overlay button (issue #115): an offset from
/// the control's default center, in *reference* points (`TouchOverlayLayout`
/// scale 1.0), so an arrangement made on a phone keeps its shape on an iPad
/// exactly as the defaults do. `TouchOverlayLayout` multiplies the offset by
/// its scale and clamps the result inside the window; a control with no
/// entry sits at its default.
///
/// Persisted in UserDefaults as plain JSON keyed by the controls'
/// accessibility identifiers (`{"fireButton":[-120,-80]}`), read once at
/// overlay-install time like `TouchTuning` and the scheme: a layout saved
/// mid-session applies to the next session. Tolerant on read, like
/// `TouchTuning.current`: garbage, an unknown control, a malformed pair or a
/// non-finite coordinate each drop that entry rather than taking the overlay
/// down with it.
struct TouchOverlayLayoutOverrides: Equatable {
    private(set) var offsets: [TouchOverlayControl: CGPoint]

    init(offsets: [TouchOverlayControl: CGPoint] = [:]) {
        self.offsets = offsets.filter { $0.value.x.isFinite && $0.value.y.isFinite }
    }

    /// The shipped layout: nothing moved.
    static let none = TouchOverlayLayoutOverrides()

    var isEmpty: Bool { offsets.isEmpty }

    /// The control's offset, or nil when it sits at its default. Setting nil
    /// (or a non-finite point, which could put a button nowhere) removes it.
    subscript(control: TouchOverlayControl) -> CGPoint? {
        get { offsets[control] }
        set {
            if let point = newValue, point.x.isFinite, point.y.isFinite {
                offsets[control] = point
            } else {
                offsets.removeValue(forKey: control)
            }
        }
    }

    static let userDefaultsKey = "touchOverlayLayoutOffsets"

    static func current(defaults: UserDefaults = .standard) -> TouchOverlayLayoutOverrides {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return .none }
        return decode(data)
    }

    /// Writes the table, or removes the key when nothing is moved so there
    /// is nothing to decode on every launch and "reset" and "never moved"
    /// are the same stored state.
    func save(to defaults: UserDefaults = .standard) {
        if offsets.isEmpty {
            defaults.removeObject(forKey: Self.userDefaultsKey)
        } else {
            defaults.set(encoded(), forKey: Self.userDefaultsKey)
        }
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    func encoded() -> Data {
        var object: [String: [Double]] = [:]
        for (control, point) in offsets {
            object[control.rawValue] = [Double(point.x), Double(point.y)]
        }
        // Every value is a finite Double by construction, so this cannot throw.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func decode(_ data: Data) -> TouchOverlayLayoutOverrides {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .none
        }
        var offsets: [TouchOverlayControl: CGPoint] = [:]
        for (key, value) in object {
            guard let control = TouchOverlayControl(rawValue: key),
                  let pair = value as? [Double], pair.count == 2,
                  pair[0].isFinite, pair[1].isFinite
            else { continue }
            offsets[control] = CGPoint(x: pair[0], y: pair[1])
        }
        return TouchOverlayLayoutOverrides(offsets: offsets)
    }
}
