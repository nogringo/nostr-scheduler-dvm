# Nostr Scheduler DVM

Portable Dart core for a Nostr Scheduler DVM.

The package accepts encrypted `kind:5905` schedule requests, publishes the
signed target event at `schedule_at`, handles `kind:5` cancellations, and sends
private encrypted `kind:7000` feedback.

## Features

- Scheduler DVM runtime for the draft Scheduler DVM protocol.
- NIP-44 request decryption and feedback encryption.
- NIP-65 relay resolution for the DVM pubkey.
- Catch-up of requests and cancellations published while the DVM was offline,
  through `sync_engine_shim_for_ndk`.
- Optional NIP-89 discovery announcement.
- Pluggable job persistence through `DvmJobStore`, with a Sembast
  implementation included.
- Portable library code: no `dart:io` imports in `lib/`.

## Usage

Use a dedicated NDK instance logged in as the DVM:

```dart
final syncEngine = SyncEngine(dvmNdk, db: database)..start();

final dvm = SchedulerDvm(
  SchedulerDvmConfig(
    ndk: dvmNdk,
    store: SembastDvmJobStore(database),
    syncEngine: syncEngine,
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
    store: SembastDvmJobStore(database),
    syncEngine: syncEngine,
    bootstrapRelays: ['wss://relay.damus.io'],
  ),
);

await dvm.start();
```

`SchedulerDvmConfig` persists jobs through the supplied `DvmJobStore` and uses
`ndk.config.eventVerifier` to validate the scheduled signed event. The caller
owns the NDK lifecycle, signer lifecycle, database lifecycle, and sync engine
lifecycle: start the engine, and dispose it after the DVM.

A request scheduled further ahead than `maxScheduleAhead` (10 years by default)
is rejected with an `error` feedback.

Live subscriptions deliver requests as they are published. The sync engine
keeps them, and the cancellations, synced into the NDK cache, so whatever was
published while the DVM was stopped or disconnected is processed on the next
pass. Give NDK a persistent cache: the engine remembers what it already
synced, so a cache emptied under it is not fetched again.

To use another database (SQLite, Drift, etc.), implement `DvmJobStore` and pass
it as `store`. `DvmJob.toJson()` and `DvmJob.fromJson()` handle serialization.

## Protocol

- Schedule requests: `kind:5905`, NIP-44 encrypted to the DVM pubkey, tagged
  with `["p", "<dvm_pubkey>"]` and `["encrypted"]`.
- Feedback: `kind:7000`, encrypted with a one-time ephemeral key, tagged with
  `["r", "<job_id>"]` and `["ephemeral-pubkey", "<ephemeral_pubkey>"]`.
- Cancellation: standard `kind:5` delete event tagging the original
  `kind:5905` event id, and carrying `["k", "5905"]` and
  `["p", "<dvm_pubkey>"]`. Deletions without both are ignored.
- Discovery: optional NIP-89 `kind:31990` announcement for `kind:5905`.

## Checks

```sh
dart format --set-exit-if-changed .
dart analyze
dart test
```
