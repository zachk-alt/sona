# Focus-safe insertion

Sona captures the frontmost application PID and available editable Accessibility, window, and document identity when a recording begins. Before posting Paste, it compares the current target with that captured target. It repeats the comparison after reading and preparing the clipboard. Cmd-V is addressed to the captured process without activating an application.

When Accessibility exposes a concrete field at both checks, Sona requires the same field identity and available document identity. Known password and noneditable controls are blocked. A cosmetic window-title update does not reject the same concrete field with a stable document.

For an unavailable or coarse Accessibility field, Mac Sona can use a compatibility path: the same frontmost PID, an exact available window identity, and an unchanged activity revision from the same recording session. Conflicting available window IDs or document identities are refused. A PID alone is insufficient. The activity guard starts before target capture and remains active through recording and processing. It observes mouse-down and key-down events in other applications and application activation changes. Those events invalidate compatibility insertion, except the configured nonmodifier finish shortcut with its matching modifiers. Sona's own nonactivating recording controls are outside the global event monitor, so using Done can finish recording without invalidating the destination. Missing monitoring or Accessibility access selects recovery.

When identity changes or compatibility cannot be established, Sona retains the completed dictation in memory and exposes **Copy Pending Dictation** in its menu. Multiple pending recordings are preserved in order and separated by a blank line when copied. An explicit successful recovery copy clears the pending queue. Pending text is not persisted, so quitting Sona discards it.

A temporary paste preserves every readable representation of every original pasteboard item, including an empty original clipboard. If a promised representation cannot be read, insertion is retained for recovery instead of replacing that clipboard. Restoration runs after the existing one-second delivery grace period and only if the pasteboard still has Sona's exact change count. Copying even identical text elsewhere establishes new ownership, so Sona leaves it alone. Rapid consecutive pastes share the original snapshot. Explicit recovery is a permanent user-requested clipboard copy and is never undone by an earlier restore callback.

## Compatibility limits

Electron and web editors sometimes expose only a group, web area, or window instead of the editable field, or report Accessibility `noValue` while a cursor is visible. Requiring a concrete field in every case prevented paste in an observed Codex session even though recording and transcription completed. The monitored-window path restores compatibility for that condition without activating an old application.

An unchanged window and no observed user activity are weaker evidence than a concrete field identity. A page can move focus programmatically inside an inaccessible window without producing an input event. Sona cannot prove that an unavailable field is editable or non-password; it refuses fields positively identified as protected or noneditable. Do not describe this fallback as equivalent to exact field matching or as universal password detection.

Accessibility identity checks and event delivery are separate macOS operations. There is no atomic check-and-paste API or delivery acknowledgment in this path. A same-process field change after the final check remains a narrow race, and a target taking more than the one-second grace period to consume Paste may not insert correctly. Do not describe posting a keyboard event as a confirmed insertion. These changes use the existing Accessibility access, without requesting another permission.

## Automated tests

From the repository root on macOS:

```sh
mkdir -p .build/insertion-tests
swiftc -module-cache-path .build/insertion-tests/module-cache \
  Sources/Murmur/FocusedElement.swift Sources/Murmur/TextInserter.swift \
  Tests/macos-insertion.swift -o .build/insertion-tests/run
.build/insertion-tests/run
```

The executable tests concrete field identity, monitored-window compatibility, blocked controls, activity revisions, the final insertion guard, and clipboard ownership with synthetic AX identities, an injected event sender, a deterministic restoration scheduler, and a temporary named pasteboard. It does not query user fields, post keyboard events, or access the general clipboard. It requires access to the macOS pasteboard service; a restrictive process sandbox can prevent the test's temporary pasteboard writes. It passed on the development Mac outside that sandbox. It does not substitute for application-level delivery checks.

## Installed native smoke test

The installed Sona bundle also passed `--insertion-selftest` with its existing Accessibility access. This test creates two disposable text fields in its own temporary window and uses the real capture, insertion, panel, and recovery code. It verified that native Cmd-V inserted the complete synthetic text exactly once, recording and processing panels preserved keyboard focus, switching fields refused automatic insertion, pending recovery copied the complete result, and the original clipboard was restored. No new permission was requested.

To repeat it, launch the installed executable directly so the test can remember the prior foreground application:

```sh
/Applications/Sona.app/Contents/MacOS/Murmur --insertion-selftest
```

This explicit test briefly activates its own window, backs up the clipboard, and restores the prior foreground application on exit unless the user has switched elsewhere. It uses no microphone, AI provider, existing document, or personal text. It stops without prompting if existing Accessibility access is unavailable or the clipboard cannot be preserved.

## Manual application QA

Use disposable documents and synthetic phrases. Keep another temporary text field available to verify refusal.

1. In TextEdit, record and finish without changing fields. Verify one insertion, unchanged keyboard focus, and restoration of a rich-text or file-copy clipboard after a second.
2. Repeat with an empty clipboard. Verify it is empty again after successful insertion.
3. While recording or processing, switch to another application. Verify no text is pasted there or into the original application and the recovery menu becomes available.
4. Repeat by changing fields in one application, and by changing windows or document tabs. Verify uncertain or changed identities produce pending dictation.
5. In Safari, test a normal editable input and a content-editable field. Verify the original field receives text once, or the recovery action is available when neither exact field matching nor monitored-window compatibility can be established.
6. In Codex and another Electron editor, test the initial editor without moving focus. Verify a coarse or unavailable AX field receives one paste only when window identity and the same session activity remain unchanged. Repeat with a finish shortcut and an owned Done control where available. Then click another field, press Tab, change tabs/windows, and switch away and back during recording or processing; each activity change must select recovery. Cosmetic task-title updates alone must not reject compatibility paste.
7. Produce two pending recordings. Use Copy Pending Dictation, paste manually into a disposable field, and verify both complete texts appear in order.
8. Copy something else during the one-second restore window, including the exact dictated text. Verify Sona preserves that new copy.

The installed test verifies delivery into Sona's own native fields. The third-party application scenarios above, including Safari and Electron editors, remain a manual release QA checklist and are not claimed as completed by that test.

The development user reproduced the unavailable-field failure in Codex, then confirmed successful insertion in the same real Codex text box after this compatibility fix was installed. The application log showed window compatibility followed by paste; no transcript contents were read for that verification.
