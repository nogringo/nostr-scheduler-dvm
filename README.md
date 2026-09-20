# Nostr Scheduler DVM

Portable Dart core for a Nostr Scheduler DVM.

The package accepts encrypted `kind:5905` schedule requests, publishes the
signed target event at `schedule_at`, handles `kind:5` cancellations, and sends
private encrypted `kind:7000` feedback.

## Features

- Scheduler DVM runtime for the draft [Scheduler DVM protocol][spec].
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

A request scheduled further ahead than `maxScheduleAhead` (10 years by default),
or asking for more than `maxRelaysPerJob` target relays (20 by default), is
rejected with an `error` feedback.

Target relays go through `targetRelayPolicy`, which accepts public `wss://`
relays only, so a request cannot point the DVM at `ws://localhost` or at a
private address of the network it runs on. The check is lexical: a hostname
that resolves to a private address still passes. For a DVM serving its own
machine, or for tests, pass `RelayUrlPolicy.permissive`:

```dart
SchedulerDvmConfig(
  ...
  targetRelayPolicy: RelayUrlPolicy.permissive,
);
```

Live subscriptions deliver requests as they are published. The sync engine
keeps them, and the cancellations, synced into the NDK cache, so whatever was
published while the DVM was stopped or disconnected is processed on the next
pass. Give NDK a persistent cache: the engine remembers what it already
synced, so a cache emptied under it is not fetched again.

To use another database (SQLite, Drift, etc.), implement `DvmJobStore` and pass
it as `store`. `DvmJob.toJson()` and `DvmJob.fromJson()` handle serialization.

## Protocol

The wire format is the [Scheduler DVM spec][spec].

One deviation from it, for backward compatibility: feedback also carries
`["ephemeral-pubkey", "<dvm_pubkey>"]`, where clients written against the
revision that encrypted feedback with a one-time key read the sender key. Pass
`legacyEphemeralPubkeyTag: false` to emit the spec tags only.

[spec]: https://openspecs.uid.ovh/spec/npub1kg4sdvz3l4fr99n2jdz2vdxe2mpacva87hkdetv76ywacsfq5leqquw5te/scheduler-dvm

## Checks

```sh
dart format --set-exit-if-changed .
dart analyze
dart test
```
