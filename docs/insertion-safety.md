# Focus-safe insertion

Sona captures the frontmost application PID, concrete editable Accessibility element, and available window/document identity when a recording begins. Before posting Paste, it compares the current target with that captured target. It repeats the comparison after reading and preparing the clipboard. Cmd-V is addressed to the captured process without activating an application.

When the field is unavailable or any captured identity changes, Sona retains the completed dictation in memory and exposes **Copy Pending Dictation** in its menu. Multiple pending recordings are preserved in order and separated by a blank line when copied. An explicit successful recovery copy clears the pending queue. Pending text is not persisted, so quitting Sona discards it.

A temporary paste preserves every readable representation of every original pasteboard item, including an empty original clipboard. If a promised representation cannot be read, insertion is retained for recovery instead of replacing that clipboard. Restoration runs after the existing one-second delivery grace period and only if the pasteboard still has Sona's exact change count. Copying even identical text elsewhere establishes new ownership, so Sona leaves it alone. Rapid consecutive pastes share the original snapshot. Explicit recovery is a permanent user-requested clipboard copy and is never undone by an earlier restore callback.

## Conservative cases

Electron and web editors sometimes expose only a group, web area, or window instead of the editable field. Sona can record there, but automatic insertion requires a concrete field identity. Those uncertain cases use the recovery menu. Changes to an available document URL or window title also select recovery, even when a title change only reflects an editor's modified-file indicator. This favors preserving words over pasting into a potentially different document.

Accessibility identity checks and event delivery are separate macOS operations. There is no atomic check-and-paste API or delivery acknowledgment in this path. A same-process field change after the final check remains a narrow race, and a target taking more than the one-second grace period to consume Paste may not insert correctly. Do not describe posting a keyboard event as a confirmed insertion. These changes use the existing Accessibility access, without requesting another permission.

## Automated tests

From the repository root on macOS:

```sh
mkdir -p .build/insertion-tests
swiftc -module-cache-path .build/insertion-tests/module-cache \
  Sources/Murmur/FocusedElement.swift Sources/Murmur/TextInserter.swift \
  tests/macos-insertion.swift -o .build/insertion-tests/run
.build/insertion-tests/run
```

The executable performs 46 assertions with synthetic AX identities, an injected event sender, a deterministic restoration scheduler, and a temporary named pasteboard. It does not query user fields, post keyboard events, or access the general clipboard. It requires access to the macOS pasteboard service; a restrictive process sandbox can prevent the test's temporary pasteboard writes. It passed on the development Mac outside that sandbox. It does not substitute for application-level delivery checks.

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
5. In Safari, test a normal editable input and a content-editable field. Verify the original field receives text once, or the recovery action is available if Accessibility cannot identify it.
6. In VS Code or another Electron editor, test the initial editor, a second tab, and a second editor group. Verify a concrete exposed text area works; a coarse AX container must select recovery. Switching to another known field or document must not paste automatically.
7. Produce two pending recordings. Use Copy Pending Dictation, paste manually into a disposable field, and verify both complete texts appear in order.
8. Copy something else during the one-second restore window, including the exact dictated text. Verify Sona preserves that new copy.

The installed test verifies delivery into Sona's own native fields. The third-party application scenarios above, including Safari and Electron editors, remain a manual release QA checklist and are not claimed as completed by that test.
