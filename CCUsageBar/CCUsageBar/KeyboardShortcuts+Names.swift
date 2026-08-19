import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleUsagePopover = Self(
        "toggleUsagePopover",
        default: .init(.u, modifiers: [.control, .option, .command])
    )
}
