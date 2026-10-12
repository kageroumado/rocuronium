import ApplicationServices
import Foundation

/// Text and caret evidence from the focused editable element around one key event.
nonisolated struct KeyTextSnapshot {
    let value: String?
    let selection: NSRange?

    init(value: String?, selection: NSRange?) {
        self.value = value
        self.selection = selection
    }

    init?(_ element: AXElement?) {
        guard let element,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(element.role),
              element.subrole != kAXSecureTextFieldSubrole else { return nil }
        value = element.string(kAXValueAttribute)
        selection = element.selectedTextRange
    }

    /// Requires readable evidence on both sides; loss of an attribute is inconclusive.
    func change(from before: Self) -> String? {
        if let value, let previous = before.value, value != previous {
            return "text changed: \(value.prefix(200))"
        }
        if let selection, let previous = before.selection, selection != previous {
            return "selection changed: location \(selection.location), length \(selection.length)"
        }
        return nil
    }
}
