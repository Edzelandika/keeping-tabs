# Keeping Tabs

A native macOS menu bar app that switches Safari tabs in most-recently-used order.

## Use

- Quickly tap **Control-Tab** to return to the last tab without a visible picker.
- Hold Control after pressing Tab to show the picker after **150 ms**.
- Use Tab/Shift-Tab or Up/Down arrows to navigate.
- Release Control or press Enter to select; Escape cancels.
- The picker shows titles, site addresses, and cached website icons.

## Build

Requires macOS 13 or later and Apple's Command Line Tools. No third-party libraries are required.

```sh
# Once per Mac: creates a persistent local signing identity.
./setup-signing.command

# Build or rebuild the app.
./build.command
```

The setup script imports a local certificate and private key into the login Keychain and requests user-level trust for code signing only. Approve any macOS authentication prompts. This is not Developer ID signing or notarization.

Quit the app before rebuilding, then open **Keeping Tabs.app**. A successful build prints `Built Keeping Tabs.app`. Terminal may leave the completed window open.

The default signing identity is **Safari Recent Tabs Local**. Preserve that identity across builds so macOS can recognize updates. Set `SAFARI_TABS_SIGNING_IDENTITY` to use another installed signing identity. The bundle identifier remains `local.safari-recent-tabs` for continuity with earlier builds. The build refuses to fall back to ad-hoc signing.

## Permissions

1. Keep the app in a permanent location and open it.
2. Enable its shortcut permission under **System Settings → Privacy & Security → Device Control and Data Access** (called **Accessibility** on earlier macOS versions).
3. Allow the app to control Safari under **Automation**.
4. Use the app's **Status…** window to check permission, keyboard-listener state, and loaded-tab count.

When migrating from an old ad-hoc build, remove the previous permission entry and add the newly signed app once. An enabled Settings toggle can refer to an obsolete signing identity. Future builds should preserve permissions when signed with the same certificate and bundle identifier.

## How it works

Keyboard navigation uses cached tab data. Safari automation runs in a persistent helper process, keeping calls off the interface thread. Switching sends four explicit Apple events: validate the front window, fetch tab URLs, select the target, and verify its index. Routine full reads still use AppleScript. Mouse releases and likely tab-changing shortcuts schedule a full title/URL refresh after a 100 ms debounce. A five-second safety timer with one second of tolerance catches changes without input while Safari is active. Activation refreshes immediately. Successful app-driven switches update history in memory immediately and reconcile with Safari after a 250 ms quiet gap. Failed switches refresh immediately. Only one read runs at a time; requests arriving during a read or picker gesture are retained. The switch handler validates the originating window and selected tab, then verifies Safari's selection. Errors appear in Status. Last-switch timings show input dispatch, helper queue wait, helper execution (including Safari/IPC), callback delivery, and validation/selection/verification stages; they do not measure when Safari finishes painting the page. Timings are kept only in memory and shown in Status, without recording tab addresses or adding per-switch disk writes.

Favicons load asynchronously from each HTTPS site's `/favicon.ico`, or Notion's `/images/favicon.ico`. Requests omit page paths, cookies, and credentials; no third-party icon service is used. The destination receives the requesting IP address, and sites may redirect requests. Images are cached in memory with a 256-icon / 4 MB cache budget. Failed requests retain the letter placeholder and are retried on the next launch. Custom page-specific icons may differ from Safari's icons.

## Scope and privacy

The app works within the frontmost Safari window and its active Tab Group. It tracks visits after launch. Very fast manual switches may be missed, and a click immediately followed by Control-Tab can use the previous cached history before the delayed refresh finishes. Background page changes may remain stale until the safety refresh. Changing windows resets the current history. It does not start automatically at login.

Safari does not expose stable tab IDs through its scripting interface. Unique URLs can be matched across tab moves, but duplicate URLs, close-and-replace operations, and Tab Group changes can make identity ambiguous and reset history.

Tab titles and URLs, including private tabs when active, remain in memory. The app does not access page contents, browsing-history databases, or screenshots. A temporary diagnostic file records the app path, permission state, tab count, and automation errors; it does not record the tab list. Website favicon requests also apply to private tabs.

## Source layout

- `Source/main.swift`: menu bar app, shortcut handling, delayed picker, and status window.
- `Source/Bridge.swift`: persistent helper and Safari automation.
- `Source/Recency.swift`: recent-tab ordering.
- `Source/Picker.swift`: picker drawing and icon cache.
- `Source/PickerKey.swift`: picker keys and refresh-triggering shortcuts.
- `Source/RefreshScheduler.swift`: debouncing and deferred read scheduling.
- `Tests/`: standalone Swift checks for recency, key mappings, and helper communication.

Compiled apps and signing keys are excluded from this repository. Each developer creates or supplies their own signing identity.
