import UIKit

/// The secure-text-field technique shared by the whole-window capture
/// protection and the per-region `ScreenshotShieldSensitiveView`.
///
/// iOS has no public API for excluding content from screenshots or screen
/// recordings. A `UITextField` with `isSecureTextEntry` enabled is rendered by
/// UIKit through a private, capture-excluded canvas layer, which is exposed as
/// one of its subviews (historically `_UITextLayoutCanvasView`). Nesting a
/// layer into that canvas layer is what excludes the content inside it from
/// system captures - adding the field next to the content protects nothing but
/// the (empty) field itself.
///
/// This depends on undocumented UIKit behaviour and can break on any iOS
/// release.
enum SecureCanvas {
    /// Creates the capture-excluded text field used as a container.
    ///
    /// The caller is expected to add the field to the hierarchy and lay it out
    /// before calling [containerLayer(of:)], because UIKit builds the canvas
    /// lazily.
    static func makeField(frame: CGRect) -> UITextField {
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.isAccessibilityElement = false
        field.frame = frame
        return field
    }

    /// The private capture-excluded layer UIKit builds inside a secure text
    /// field. The field's last sublayer is used as a fallback for the same
    /// layer when the canvas view cannot be identified.
    static func containerLayer(of field: UITextField) -> CALayer? {
        if let canvas = canvasView(in: field) {
            log("secure canvas view: \(NSStringFromClass(type(of: canvas))), frame \(canvas.frame)")
            return canvas.layer
        }
        let subviews = field.subviews.map { NSStringFromClass(type(of: $0)) }
        log("no secure canvas view on the text field; subviews: \(subviews)")
        return field.layer.sublayers?.last
    }

    private static func canvasView(in view: UIView) -> UIView? {
        for subview in view.subviews {
            if NSStringFromClass(type(of: subview)).range(of: "canvas", options: .caseInsensitive) != nil {
                return subview
            }
            if let match = canvasView(in: subview) {
                return match
            }
        }
        return nil
    }

    /// Diagnostics while debugging a device build; capture exclusion relies on
    /// undocumented UIKit behaviour, so it is worth being able to see whether a
    /// layer was actually nested in the secure container.
    static func log(_ message: String) {
        #if DEBUG
            NSLog("[ScreenshotShield] \(message)")
        #endif
    }
}
