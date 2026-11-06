import AppKit

/// Go to Date: a month of the notebook. Days you wrote on are in ink with a dot under them, the
/// rest are faint; today has a ring. Arrows move by day and week, Page Up/Down by month, Return
/// goes, Escape closes. A day without writing takes you to the next one that has it.
@MainActor
final class DatePopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var grid: MonthView?
    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }
    func close() { popover.animates = false; popover.close(); popover.animates = true }

    func show(from item: NSToolbarItem, written: Set<String>, first: Date, onPick: @escaping (String) -> Void) {
        if popover.isShown { close(); return }
        let month = MonthView(written: written, first: first) { [weak self] key in
            self?.close()
            onPick(key)
        }
        grid = month
        let controller = NSViewController()
        controller.view = month
        popover.contentViewController = controller
        popover.contentSize = month.fittingSize
        popover.show(relativeTo: item)
        month.window?.makeFirstResponder(month)
    }
}

@MainActor
final class MonthView: NSView {
    private let written: Set<String>
    private let first: Date
    private let onPick: (String) -> Void
    private let calendar = Calendar.current
    private var month: Date       // first of the month shown
    private var focused: Date     // the day the keyboard is on

    private let title = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private var dayButtons: [NSButton] = []

    private static let cell: CGFloat = 34
    private static let pad: CGFloat = 14

    init(written: Set<String>, first: Date, onPick: @escaping (String) -> Void) {
        self.written = written
        self.first = first
        self.onPick = onPick
        let today = calendar.startOfDay(for: Date())
        focused = today
        month = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        super.init(frame: .zero)
        build()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: Self.pad * 2 + Self.cell * 7, height: Self.pad * 2 + 30 + 22 + Self.cell * 6)
    }

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Go to Date"))

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        addSubview(title)
        for (button, symbol, label, action) in [(previous, "chevron.left", String(localized: "Previous Month"), #selector(previousMonth)),
                                                (next, "chevron.right", String(localized: "Next Month"), #selector(nextMonth))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.target = self
            button.action = action
            button.toolTip = label
            addSubview(button)
        }
        // Weekday initials, starting where the user's week starts.
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        for i in 0..<7 {
            let label = NSTextField(labelWithString: symbols[(i + calendar.firstWeekday - 1) % 7])
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.setAccessibilityElement(false)
            label.frame = NSRect(x: Self.pad + CGFloat(i) * Self.cell, y: Self.pad + Self.cell * 6, width: Self.cell, height: 18)
            addSubview(label)
        }
        for i in 0..<42 {
            let b = DayButton()
            b.target = self
            b.action = #selector(pick(_:))
            b.frame = NSRect(x: Self.pad + CGFloat(i % 7) * Self.cell, y: Self.pad + CGFloat(5 - i / 7) * Self.cell, width: Self.cell, height: Self.cell)
            addSubview(b)
            dayButtons.append(b)
        }
        let size = fittingSize
        title.frame = NSRect(x: Self.pad + 4, y: size.height - Self.pad - 24, width: 180, height: 22)
        previous.frame = NSRect(x: size.width - Self.pad - 60, y: size.height - Self.pad - 26, width: 28, height: 26)
        next.frame = NSRect(x: size.width - Self.pad - 28, y: size.height - Self.pad - 26, width: 28, height: 26)
    }

    private func reload() {
        title.stringValue = month.formatted(.dateTime.month(.wide).year())
        let today = calendar.startOfDay(for: Date())
        let firstMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: first))!
        previous.isEnabled = month > firstMonth
        next.isEnabled = month < calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: month)!.count
        for (i, button) in dayButtons.enumerated() {
            let b = button as! DayButton
            let n = i - lead + 1
            guard n >= 1, n <= days, let date = calendar.date(byAdding: .day, value: n - 1, to: month) else { b.isHidden = true; continue }
            let key = NotebookStore.key(date)
            b.isHidden = false
            b.day = date
            b.title = "\(n)"
            b.hasWriting = written.contains(key)
            b.isToday = date == today
            b.isFocused = date == focused
            b.isEnabled = date <= today
            b.setAccessibilityLabel(NotebookIndex.longDate(key) + (b.hasWriting ? "" : ", " + String(localized: "nothing written")))
            b.needsDisplay = true
        }
    }

    @objc private func previousMonth() { moveMonth(-1) }
    @objc private func nextMonth() { moveMonth(1) }

    private func moveMonth(_ delta: Int) {
        guard let m = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        month = m
        focused = calendar.date(byAdding: .month, value: delta, to: focused) ?? m
        clampFocus()
        reload()
    }

    private func moveFocus(days: Int) {
        guard let d = calendar.date(byAdding: .day, value: days, to: focused) else { return }
        focused = d
        clampFocus()
        month = calendar.date(from: calendar.dateComponents([.year, .month], from: focused))!
        reload()
    }

    private func clampFocus() {
        let today = calendar.startOfDay(for: Date())
        focused = min(max(focused, calendar.startOfDay(for: first)), today)
    }

    @objc private func pick(_ sender: DayButton) {
        guard let day = sender.day else { return }
        onPick(NotebookStore.key(day))
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 123: moveFocus(days: -1)
        case 124: moveFocus(days: 1)
        case 126: moveFocus(days: -7)
        case 125: moveFocus(days: 7)
        case 116: moveMonth(-1)
        case 121: moveMonth(1)
        case 36, 76, 49: onPick(NotebookStore.key(focused))
        default: super.keyDown(with: event)
        }
    }
}

/// One day: a number; ink with a dot when something was written, faint otherwise; a ring for today,
/// a filled circle for the keyboard's day.
final class DayButton: NSButton {
    var day: Date?
    var hasWriting = false
    var isToday = false
    var isFocused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }   // the dot goes under the number

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 4, dy: 4)
        if isFocused {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
        } else if isToday {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let ink: NSColor = isFocused ? .white : (hasWriting ? .labelColor : (isEnabled ? .tertiaryLabelColor : .quaternaryLabelColor))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: hasWriting ? .semibold : .regular)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 + (hasWriting ? 2 : 0)))
        if hasWriting {
            (isFocused ? NSColor.white : NSColor.controlAccentColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1.5, y: bounds.midY - size.height / 2 - 3, width: 3, height: 3)).fill()
        }
    }
}
