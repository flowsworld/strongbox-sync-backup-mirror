# Notification verification for issue #6

Verified on 2 October 2026 with macOS 27.0.1, Xcode 27 and an ad-hoc signed,
sandboxed native app. This work covers local-copy notifications. Cloud events
remain outside this issue.

## Isolation and method

The native fixture app used a separate bundle identity, container and settings
file. It created an artificial source and a dedicated target inside its own
sandbox. It used the normal `AppModel`, scheduler, file monitor,
`NotificationService`, `ApplicationDelegate` and settings view. Its alternate
bootstrap supplied the fixture settings and folder resolver through
`AppEnvironment`. A temporary control runner invoked the model's existing
notification actions and changed only those artificial files.

Authorization changes used the real macOS prompt and the fixture app's entry in
System Settings. Delivery counts came from
`UNUserNotificationCenter.getDeliveredNotifications`, rather than counting
successful `add` calls. Database selections used actual accessibility presses
on the fixture notifications in Notification Center. Neither selection test
called the model's selection callback directly.

The first bundle in a temporary directory failed macOS client validation.
Registration and launching the dedicated bundle from `~/Applications` resolved
that failure. The fixture process was stopped after a completed check before
restart checks. An early control-runner quit command entered AppKit termination
from a Swift task and stalled that runner; restart checks used process termination
instead. This does not establish ordinary app shutdown behavior, which belongs
to issue #5.

No real Strongbox source, existing shell helper, LaunchAgent, daily-use target,
login setting or other running app was changed. Published evidence contains no
database names, identifiers, checksums, contents or screenshots.

## Native results

| Check | Observed result |
| --- | --- |
| Initial authorization action and denial | The native permission notice appeared. Selecting "Nicht erlauben" left authorization denied. The explicit test action delivered nothing. |
| Events while denied | A changed copy and a target error entered history. No notification was delivered. Repeating the error added neither another alert nor another history entry. |
| Later permission grant | Enabling only the fixture app in System Settings changed native authorization to authorized. Rechecking delivered no old events. The test action delivered one test notification. |
| Copy category by itself | One changed copy delivered one copy notification. An unchanged check kept the count at one. Turning copies off and changing the source again added history but no notification. |
| Per-database error and recovery | An unavailable fixture target delivered one error. Restoring it delivered one recovery with recoveries selected and copies disabled. |
| Global source recovery | With failures disabled and recoveries selected, an unavailable fixture source delivered no error. Restoring it delivered one global recovery. |
| Global error repetition and restart | With errors selected alone, one source error delivered one notification. An unchanged check and a fresh process retained the saved failure without another notification or another failure history entry. |
| Recurrence after recovery | Recovering the source cleared the saved failure. Making it unavailable again delivered a new error; another unchanged check stayed silent. |
| Later permission revocation | Disabling only the fixture app's OS permission prevented delivery of a new copy event and preserved it in history. Re-enabling permission did not replay that event. The next explicit test and changed-copy events were delivered. |
| First settings window | Clicking a database notification created the settings window, selected Databases and expanded that database's details. |
| Selection after collapse | After collapsing the details, clicking a subsequent database notification expanded them again in the existing window. |

The system reported active display sharing and suppressed interrupting banners.
The notifications were present in the native delivered list and Notification
Center, where click behavior was verified. Global notification preferences were
not changed to bypass this suppression. Banner appearance and sound during an
unshared session, other macOS versions, and production signing remain unverified.
These are OS presentation limits, rather than evidence of failed scheduling.

## Automated coverage and validation

- The full native suite passed: 29 core and 40 app test functions.
- Eight notification test functions exercise 16 cases. They use the normal
  model with temporary settings and sources, plus injected notification effects.
  They never instantiate the OS notification center or request OS permission.
- All eight combinations of category preferences are covered, along with the
  default choices, unchanged checks, persisted failure suppression, new and
  recurring failures, global and database recovery, denied and undetermined
  authorization, later grant/revocation, the explicit test action and repeated
  detail selection.
- A failing test reproduced delivery after turning a category off while its
  authorization query was suspended. The fix revalidates the event after that
  query. Other focused cases cover disabling and re-enabling during the query,
  and disabling during system submission. Accepted pending requests are removed;
  old requests from an earlier process are discarded at startup.
- All 107 existing Python tests passed. The release app built and passed
  ad-hoc signature verification. The final named-field cleanup was checked with
  the focused notification suite and another release build. A final startup check also verifies that only the
  process owning the settings lock discards stale requests.

## Independent review

The Standards review found no documented-standard violation and suggested
replacing positional notification tuple fields with named fields. That suggestion
was implemented. The Spec review found no incorrect implementation, missing state
decision or scope creep. No findings were dismissed. The clients' cross-model
review step applies to Claude Code and was skipped in this Codex session.

## Cleanup

The fixture app's notification permission was switched off, its delivered
notifications cleared, and its process stopped. Its app registration, dedicated
app bundle, sandbox container, artificial files, temporary runner and local UI
captures were removed. Other apps and notification preferences were left intact.
