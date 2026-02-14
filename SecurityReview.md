# iMCP Security Review

Last applied: 2026-02-11

## Findings & Remediations

### 1. Sparkle Auto-Update References (Removed)

**Finding:** `Info.plist` contained `SUEnableInstallerLauncherService`, `SUFeedURL`, `SUPublicEDKey` keys but no Sparkle framework was linked. Dead config with a public key sitting in the binary.

**Fix:** Removed all three keys from `App/Info.plist`.

**Files:** `App/Info.plist`

---

### 2. Bonjour Network Discovery (Replaced with Port File)

**Finding:** The app advertised `_mcp._tcp` via Bonjour, making the MCP server discoverable by any process on the local network. The CLI used `NWBrowser` to find it.

**Fix:** Removed Bonjour advertisement and `NWBrowser` from both app and CLI. The TCP listener still binds localhost-only. On `.ready`, the app writes its port to `~/Library/Application Support/iMCP/server.port`. The CLI polls that file (30s timeout) and connects directly to `127.0.0.1:<port>`. Port file is deleted on stop/restart.

**Files:** `App/Info.plist` (removed `NSBonjourServices`), `App/Controllers/ServerController.swift`, `CLI/main.swift`

---

### 3. Per-Tool Confirmation (Added)

**Finding:** Once a client connection was approved, it had unrestricted access to all enabled tools with no further consent.

**Fix:** Added sticky per-tool approval. On first use of each tool by a client, a dialog prompts: "Allow [client] to use [tool]?" with an "Always Allow" checkbox. Approvals persist in `UserDefaults` (`toolApprovals` key) as `{clientName: [toolNames]}`. Approvals can be viewed and revoked in Settings > Tool Approvals.

**Files:** `App/Controllers/ServerController.swift`, `App/Views/ConnectionApprovalView.swift` (added `ToolApprovalView`, `ToolApprovalWindowController`), `App/Views/SettingsView.swift`

---

### 4. Shortcuts Allowlist (Added)

**Finding:** `shortcuts_run` could execute any shortcut on the system. A compromised or malicious MCP client could run arbitrary Shortcuts.

**Fix:** Added an allowlist (`allowedShortcuts` in `UserDefaults`). `shortcuts_run` checks the list before execution and returns an error if the shortcut isn't allowed. `shortcuts_list` remains unrestricted (read-only). The allowlist is managed in Settings > Shortcuts.

**Files:** `App/Services/Shortcuts.swift`, `App/Controllers/ServerController.swift`, `App/Views/SettingsView.swift`

---

### 5. Health Entitlement (Removed)

**Finding:** Both entitlements files declared `com.apple.security.personal-information.health` but no code uses HealthKit.

**Fix:** Removed the key from both files.

**Files:** `App/App.entitlements`, `App/App.Debug.entitlements`

## Re-applying After Upstream Pull

If pulling from the parent repo overwrites these changes, re-check:

1. `Info.plist` -- no `SU*` keys, no `NSBonjourServices`
2. `App.entitlements` / `App.Debug.entitlements` -- no health key
3. `ServerController.swift` -- `NetworkDiscoveryManager` has no `listener.service` or `NWBrowser`, has port file logic, has `toolApprovalHandler` wiring
4. `CLI/main.swift` -- no `NWBrowser`, uses `discoverPort()` from port file
5. `Shortcuts.swift` -- `isShortcutAllowed` guard before `runShortcut`
6. `SettingsView.swift` -- has `ToolApprovalsSettingsView` and `ShortcutsSettingsView` sections
7. `ConnectionApprovalView.swift` -- has `ToolApprovalView` and `ToolApprovalWindowController`
