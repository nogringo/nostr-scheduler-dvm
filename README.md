# Nostr Scheduler DVM

Portable Dart core for a Nostr Scheduler DVM.

The package accepts encrypted `kind:5905` schedule requests, publishes the
signed target event at `schedule_at`, handles `kind:5` cancellations, and sends
private encrypted `kind:7000` feedback.

## Features

- Scheduler DVM runtime for the draft Scheduler DVM protocol.
- NIP-44 request decryption and feedback encryption.
- NIP-65 relay resolution for the DVM pubkey.
- Optional NIP-89 discovery announcement.
- Sembast-backed persistence with the database supplied by the caller.
- Portable library code: no `dart:io` imports in `lib/`.

## Usage

Use a dedicated NDK instance logged in as the DVM:

```dart
final dvm = SchedulerDvm(
  SchedulerDvmConfig(
    ndk: dvmNdk,
    database: database,
    bootstrapRelays: ['wss://relay.damus.io'],
  ),
);

await dvm.start();
```

Or embed a DVM in an app that already has an NDK account logged in by passing
the Scheduler DVM signer explicitly:

```dart
final dvm = SchedulerDvm(
  SchedulerDvmConfig(
    ndk: appNdk,
    signer: schedulerDvmSigner,
    database: database,
    bootstrapRelays: ['wss://relay.damus.io'],
  ),
);

await dvm.start();
```

`SchedulerDvmConfig` builds its internal job store from the supplied Sembast
database and uses `ndk.config.eventVerifier` to validate the scheduled signed
event. The caller owns the NDK lifecycle, signer lifecycle, and database
lifecycle.

## Protocol

- Schedule requests: `kind:5905`, NIP-44 encrypted to the DVM pubkey, tagged
  with `["p", "<dvm_pubkey>"]` and `["encrypted"]`.
- Feedback: `kind:7000`, encrypted with a one-time ephemeral key, tagged with
  `["r", "<job_id>"]` and `["ephemeral-pubkey", "<ephemeral_pubkey>"]`.
- Cancellation: standard `kind:5` delete event tagging the original
  `kind:5905` event id.
- Discovery: optional NIP-89 `kind:31990` announcement for `kind:5905`.

## Checks

```sh
dart format --set-exit-if-changed .
dart analyze
dart test
```
