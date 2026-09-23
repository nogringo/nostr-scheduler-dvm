## 0.5.1

- Require `ndk: ^0.10.0-dev.6` and `sync_engine_shim_for_ndk: ^0.7.1`. 0.5.0
  accepts ndk 0.10.0-dev.6 but does not compile against it, since that release
  renames `RelayAuth` to `AuthPolicy`.

## 0.5.0

- **Behavior change:** a target relay asking for NIP-42 is answered with a key
  generated for that publish alone, instead of whichever account NDK happened
  to have logged in. A relay can no longer tie two scheduled events to the same
  DVM, and an embedded DVM no longer authenticates as the app's own user. Pass
  `targetRelayAuth: TargetRelayAuth.dvm` for a DVM whitelisted on the relays it
  publishes to, or `TargetRelayAuth.never` to fail the publish rather than name
  anyone. A refused publish now reports why instead of timing out silently.
- **Breaking:** require `ndk: ^0.10.0-dev.5`.

## 0.4.0

- **Breaking:** `DvmJobStore.getJob(jobId)` becomes
  `getJobByClientJobId(clientPubkey:, jobId:)`, and jobs are keyed by their
  request event id, so a `job_id` is unique per client instead of globally.
  Sembast records are rekeyed on first access.
- **Breaking:** `FeedbackPublisher` no longer takes a `signerFactory`.
- **Breaking:** `kind:7000` feedback is encrypted with the DVM key, as the spec
  now describes. It still carries `["ephemeral-pubkey", "<dvm_pubkey>"]` for
  older clients; pass `legacyEphemeralPubkeyTag: false` for the spec tags only.
- **Behavior change:** target relays go through `targetRelayPolicy`, public
  `wss://` only, so a request cannot aim the DVM at `ws://localhost` or at a
  private address. `RelayUrlPolicy.permissive` keeps the previous behavior.
- New limits: `maxScheduleAhead` (10 years) and `maxRelaysPerJob` (20) are
  turned down with an `error` feedback, `maxScheduleBehind` (one week) is
  ignored outright so a DVM restarted after a long outage publishes no backlog,
  and `maxRememberedEvents` (10000) caps the event ids held in memory.
- A distant `schedule_at` no longer overflows its `Duration` and fires at once,
  which left the job rescheduling itself in a loop that survived restarts.
- A request is decided once, not once per restart. A rejected one leaves no job
  behind, so nothing remembered the decision and every start sent its client
  the same `error` feedback again; the outcome now goes to the NDK decrypted
  payload sidecar. A request that fails to decrypt is still retried.
- A cancellation naming a request the DVM has not seen is no longer kept in
  memory, forever, under a key its sender chose. The request looks its own
  cancellation up in the NDK cache instead, which also survives a restart.
- The catch-up sweep no longer reloads every cached `kind:5905` and `kind:5` on
  every sync tick. It starts at `cacheSweepFloor`, derived from the coverage the
  sync engine reports, and falls back to the whole cache whenever a relay has a
  gap reaching back to the epoch.
- Live subscriptions write to the NDK cache.

## 0.3.0

- **Breaking:** `SchedulerDvmConfig` takes a `DvmJobStore store` instead of a Sembast `database`. Pass `SembastDvmJobStore(database)` to keep the previous behavior, or your own `DvmJobStore` implementation to use another database.
- **Breaking:** `SchedulerDvmConfig` requires a caller-owned `SyncEngine` from `sync_engine_shim_for_ndk`. Schedule requests and `["k", "5905"]` cancellations are synced into the NDK cache and processed from there, so events published while the DVM was offline or disconnected are no longer missed.
- **Breaking:** require `ndk: ^0.10.0-dev.3`.
- **Breaking:** cancellations must carry `["k", "5905"]` and `["p", "<dvm_pubkey>"]`, as the Scheduler DVM spec requires. The DVM only syncs the `kind:5` addressed to it instead of every `kind:5` of its relays.
- `resync()` refreshes the sync engine instead of re-querying the whole history.
- A deletion of an already cancelled job no longer sends an error feedback.

## 0.2.2

- Widen the `ndk` constraint to `>=0.9.0 <0.11.0` so apps on the 0.10 series can depend on this package.

## 0.2.1

- Test against `nostr_event_scheduler: ^0.4.0`.

## 0.2.0

- Require `ndk: ^0.9.0`.
- Updated dev dependencies (`bip340`, `broadcast_queue_shim_for_ndk`, `lints`, `test`).

## 0.1.1

- Let NDK generate subscription ids instead of hardcoding them.
- Rely on NDK defaults for query timeouts and metadata caching.

## 0.1.0

- Extracted portable Scheduler DVM library.
- Added optional `signer` support for app-embedded DVM instances.
- Added Sembast-backed persistence from a caller-supplied database.
- Added protocol tests.
