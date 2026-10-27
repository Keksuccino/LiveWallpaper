import SwiftUI
import AppKit

// The birthdate check in front of NSFW wallpapers (WorkshopAgeCheck): a dialog with a date entry of the app's own,
// three glass boxes for day, month and year in the order the user's region writes a date.

/// Asks for the user's birthdate before NSFW wallpapers show: an adult's switches them on (`confirmed`) and is
/// remembered; a minor's leaves them off and says why.
struct BirthdateDialog: View {
    let confirmed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var birthdate: Date?
    @State private var tooYoung = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if tooYoung { refusal } else { form }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .transition(.opacity)

            HStack(spacing: 12) {
                Spacer()
                if tooYoung {
                    Button("OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Continue", action: check)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(birthdate == nil)
                }
            }
            .padding([.horizontal, .bottom], 18)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(WMBackground())
    }

    private var form: some View {
        VStack(spacing: 14) {
            heading("NSFW wallpapers are 18+",
                    message: "Enter your birthdate to see them. You only need to do this once.")
            BirthdateField(date: $birthdate, submit: check, cancel: { dismiss() })
                .padding(.top, 6)
        }
    }

    private var refusal: some View {
        VStack(spacing: 14) {
            heading("You’re not old enough yet", message: "NSFW wallpapers are only for people 18 and older.")
        }
    }

    private func heading(_ title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }

    private func check() {
        guard let birthdate else { return }
        if WorkshopAgeCheck.confirm(birthdate) {
            confirmed()
            dismiss()
        } else {
            withAnimation(WMMotion.content) { tooYoung = true }
        }
    }
}

/// Day, month and year as three boxes of digits, in the order the user's region writes a date. A full box moves the
/// typing on to the next one, digits typed past its end go on into the next box, Backspace in an empty box goes back
/// into the one before, Return submits and Escape cancels. Below the boxes, the day they make in words, or a hint
/// while they make none. `date` is that day, nil until the boxes make a real day in the past.
struct BirthdateField: View {
    @Binding var date: Date?
    let submit: () -> Void
    let cancel: () -> Void

    enum Part: Hashable {
        case day, month, year

        var length: Int { self == .year ? 4 : 2 }

        /// Typing can go on to the next box: it holds all its digits, or one no second digit could follow (a day of 4
        /// to 9, a month of 2 to 9).
        func isFull(_ digits: String) -> Bool {
            if digits.count == length { return true }
            guard digits.count == 1, let value = Int(digits) else { return false }
            switch self {
            case .day: return value > 3
            case .month: return value > 1
            case .year: return false
            }
        }
    }

    @State private var texts: [Part: String] = [:]
    @State private var focus: Part?

    /// The parts in the order of the region's short date format ("dd.MM.yyyy", "MM/dd/yyyy", "yyyy/MM/dd").
    private static let order: [Part] = {
        let format = DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: .current) ?? "ddMMyyyy"
        let letters: [(part: Part, letter: Character)] = [(.day, "d"), (.month, "M"), (.year, "y")]
        let position = { (letter: Character) in format.firstIndex(of: letter) ?? format.endIndex }
        return letters.sorted { position($0.letter) < position($1.letter) }.map(\.part)
    }()

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Self.order, id: \.self, content: box)
            }
            // Always its height, shown or not, so the dialog keeps its size as the line comes and goes.
            ZStack {
                Color.clear
                status
            }
            .font(.callout)
            .frame(height: 18)
            .animation(WMMotion.content, value: date)
        }
        .onAppear { focus = Self.order.first }
        .onChange(of: texts) {
            date = WorkshopAgeCheck.birthdate(day: texts[.day] ?? "", month: texts[.month] ?? "",
                                              year: texts[.year] ?? "")
        }
    }

    private func box(_ part: Part) -> some View {
        let focused = focus == part
        return VStack(spacing: 6) {
            Text(label(part))
                .font(.caption.weight(.semibold))
                .foregroundStyle(focused ? AnyShapeStyle(WMTheme.accent) : AnyShapeStyle(.secondary))
            DigitField(text: text(part), length: part.length, placeholder: part == .year ? "0000" : "00",
                       label: label(part), focused: focused) { handle($0, in: part) }
                .padding(.horizontal, 6)
                .frame(width: part == .year ? 96 : 64, height: 50)
                .background {
                    // The box around the field takes clicks too: a click on its padding edits this part.
                    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    shape.fill(.regularMaterial)
                        .overlay(shape.strokeBorder(focused ? WMTheme.accent : Color.primary.opacity(0.12),
                                                    lineWidth: focused ? 2 : 1))
                        .contentShape(shape)
                        .onTapGesture { focus = part }
                }
                .textFieldClickArea()
        }
        .animation(WMMotion.hover, value: focused)
    }

    /// The day in words once the boxes make one; a hint once they are filled in but make none.
    @ViewBuilder private var status: some View {
        if let date {
            Text(date.formatted(date: .long, time: .omitted))
                .foregroundStyle(.secondary)
                .transition(.opacity)
        } else if Self.order.allSatisfy({ !(texts[$0] ?? "").isEmpty }), texts[.year]?.count == 4 {
            Text("That date doesn’t look right.")
                .foregroundStyle(.orange)
                .transition(.opacity)
        }
    }

    private func label(_ part: Part) -> String {
        switch part {
        case .day: return String(localized: "Day")
        case .month: return String(localized: "Month")
        case .year: return String(localized: "Year")
        }
    }

    private func text(_ part: Part) -> Binding<String> {
        Binding { texts[part] ?? "" } set: { texts[part] = $0 }
    }

    private func neighbour(of part: Part, by step: Int) -> Part? {
        guard let index = Self.order.firstIndex(of: part), Self.order.indices.contains(index + step) else { return nil }
        return Self.order[index + step]
    }

    private func handle(_ event: DigitField.Event, in part: Part) {
        switch event {
        case .focused:
            focus = part
        case .typed:
            // A full box hands the typing on, a lone day or month digit written with its zero ("4" → "04").
            let digits = texts[part] ?? ""
            guard part.isFull(digits) else { return }
            if digits.count < part.length { texts[part] = "0" + digits }
            if let next = neighbour(of: part, by: 1) { focus = next }
        case .overflow(let rest):
            guard let next = neighbour(of: part, by: 1) else { return }
            texts[next] = String(rest.prefix(next.length))
            focus = next
        case .backspaceAtStart:
            guard let previous = neighbour(of: part, by: -1) else { return }
            texts[previous] = String((texts[previous] ?? "").dropLast())
            focus = previous
        case .next:
            if let next = neighbour(of: part, by: 1) { focus = next }
        case .previous:
            if let previous = neighbour(of: part, by: -1) { focus = previous }
        case .submit:
            submit()
        case .cancel:
            cancel()
        }
    }
}

/// One box's digits, on an AppKit text field: it shows exactly what it holds (digits only, at most `length`), takes
/// focus when `focused` says so, and tells its box about typing and about the keys that move between boxes. SwiftUI's
/// TextField would keep showing what was typed when its binding refuses it, and drops focus changes made while it
/// edits.
private struct DigitField: NSViewRepresentable {
    enum Event {
        case focused, typed, overflow(String), backspaceAtStart, next, previous, submit, cancel
    }

    @Binding var text: String
    let length: Int
    let placeholder: String
    let label: String
    let focused: Bool
    let onEvent: (Event) -> Void

    private static let font: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 24) } ?? base
    }()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = Self.font
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: centered,
        ])
        field.setAccessibilityLabel(label)
        field.delegate = context.coordinator
        let coordinator = context.coordinator
        field.onFocus = { [weak coordinator] in coordinator?.parent.onEvent(.focused) }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if focused, field.currentEditor() == nil {
            // After this update: making it first responder ends another box's editing, which reports back.
            DispatchQueue.main.async {
                if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            }
        }
    }

    final class Field: NSTextField {
        var onFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            // Not while AppKit hands focus around: the box's state changes on the next pass.
            DispatchQueue.main.async { [weak self] in self?.onFocus?() }
            return true
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DigitField

        init(_ parent: DigitField) { self.parent = parent }

        /// Keeps the digits that fit, and hands those typed past the box's end to the next box.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let digits = field.stringValue.filter { $0.isASCII && $0.isNumber }
            let kept = String(digits.prefix(parent.length))
            let rest = String(digits.dropFirst(parent.length))
            if kept != field.stringValue { field.stringValue = kept }
            parent.text = kept
            parent.onEvent(rest.isEmpty ? .typed : .overflow(rest))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)) where textView.selectedRange() == NSRange(location: 0, length: 0):
                parent.onEvent(.backspaceAtStart)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onEvent(.submit)
            case #selector(NSResponder.insertTab(_:)):
                parent.onEvent(.next)
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onEvent(.previous)
            case #selector(NSResponder.cancelOperation(_:)):
                // The field editor takes Escape for itself: without this the dialog's Cancel never hears it.
                parent.onEvent(.cancel)
            default:
                return false
            }
            return true
        }
    }
}
