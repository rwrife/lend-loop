# Notification permission and verification

Lend Loop schedules optional reminders entirely on the device. It does not use
an account, network service, analytics, contacts, or remote push notifications.
Android declares `POST_NOTIFICATIONS`; iOS local-notification authorization is
requested through `UNUserNotificationCenter` and needs no usage-description key.
The in-app action is labelled **Enable due reminder**, and the denial message
states that the exchange remains available.

Permission is requested only after the user taps **Enable due reminder** for the
first persisted reminder. Opening, creating, editing, searching, returning, and
reopening exchanges never requests notification permission. Denial creates no
persisted reminder and does not disable any exchange workflow.

## Automated evidence

Run:

```sh
flutter test test/application/reminder_coordinator_test.dart
flutter test test/features/exchanges/reminders_search_accessibility_test.dart
flutter test
```

The coordinator tests cover grant and denial, serialized ID allocation under a
forced concurrent collision, update, cancel, removal of ineligible reminders,
and reconciliation that replaces every eligible future notification, including
stale content and dates under an unchanged platform ID. They also verify that a
scheduling failure persists the desired reminder and reports delivery pending.

The startup and widget tests cover unavailable plugin initialization separately
from transient reconciliation failure, retained reminder controls, an accessible
degraded-state message and successful in-session retry, notification navigation,
missing records, and combined filters. Accessibility assertions exercise 2x text
on the exchange list, record-handoff form, and details screen; explicit semantic
sort order for the search/person/direction/status controls; and measured 48dp
minimum targets for the record action, exchange row, form photo/save actions,
and details due-date/reminder/return actions. These tests use adapters and widget
fakes, not an operating-system dialog, screen reader, or physical keyboard.

## Simulator/emulator checklist

On an Android API 33+ emulator and an iOS 16+ simulator, install from a clean
state and verify that no notification prompt appears at launch or while editing.
Enable the first reminder, grant or deny the prompt, and confirm the stated app
behavior. Grant permission, schedule a reminder a few minutes ahead, restart the
app, and tap the delivered notification. Confirm it opens the matching exchange.
Delete that exchange's local test database only in a disposable install, tap an
old delivered notification, and confirm the safe missing-exchange message.

## Physical-device checklist

Repeat the preceding checks on one supported Android device and one supported
iPhone, including a reboot before delivery and an app restart for reconciliation.
Record OS/device versions and observed delivery time in the release notes.

No simulator or physical-device run is claimed by this repository change. Those
checks require interactive platform environments; automated Flutter tests are
reported separately and must not be described as device verification.
