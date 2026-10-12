import AppKit

@MainActor
extension NSApplication {
    /// Distributed notification posted when windows or tabs open, close, or
    /// change focus. External tools (e.g. sketchybar) can subscribe to it.
    static let ghosttyTabsChanged = Notification.Name("com.mitchellh.ghostty.tabsChanged")

    /// Posts `ghosttyTabsChanged` with the full window/tab list as userInfo.
    ///
    /// Deferred to the next run loop turn so a closing window has left
    /// `NSApp.windows` and a new key window is set.
    func postTabsChanged() {
        DispatchQueue.main.async {
            let windows: [[String: Any]] = NSApp.scriptWindows.map { window in
                let tabs = window.tabs
                return [
                    "id": window.stableID,
                    "title": window.title,
                    "focused": tabs.contains { $0.parentWindow?.isKeyWindow == true },
                    "tabs": tabs.map { tab in
                        [
                            "id": tab.idValue,
                            "index": tab.index,
                            "title": tab.title,
                            "selected": tab.selected,
                        ] as [String: Any]
                    },
                ]
            }

            DistributedNotificationCenter.default().postNotificationName(
                Self.ghosttyTabsChanged,
                object: nil,
                userInfo: ["windows": windows],
                deliverImmediately: true
            )
        }
    }
}
