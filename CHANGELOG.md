## 0.3.1

- Encrypt `kind:7000` feedback with the DVM key, as the spec now describes,
  instead of a one-time ephemeral key. Feedback still carries
  `["ephemeral-pubkey", "<dvm_pubkey>"]`, so clients that read the sender key
  from that tag keep decrypting; pass
  `SchedulerDvmConfig(legacyEphemeralPubkeyTag: false)` to emit the spec tags
  only. The tag will be dropped in a future release.
- **Breaking:** `FeedbackPublisher` no longer takes a `signerFactory`. Nothing
  creates a key pair per feedback any more.
- **Breaking:** `DvmJobStore.getJob(jobId)` is replaced by
  `getJobByClientJobId(clientPubkey:, jobId:)`, and jobs are keyed by their
  request event id. A `job_id` is unique per client instead of globally, so a
  client can no longer take a `job_id` away from another, by accident or to
  block it. Existing Sembast records are rekeyed on first access.
- Reject a `schedule_at` further ahead than `SchedulerDvmConfig.maxScheduleAhead`
  (10 years by default) with an `error` feedback. A far enough `schedule_at`
  overflowed `Duration` and fired its timer at once, so the job rescheduled
  itself in a loop that survived restarts.
- Chain the wait for a distant job into timers of at most a day, so a job
  already stored with such a `schedule_at` no longer loops either.
- Reject a request asking for more than `SchedulerDvmConfig.maxRelaysPerJob`
  target relays (20 by default) with an `error` feedback.
- **Behavior change:** target relays now go through
  `SchedulerDvmConfig.targetRelayPolicy`, which accepts public `wss://` relays
  only. A request could previously point the DVM at `ws://localhost` or at a
  private address, and have it connect from inside its own network. Pass
  `RelayUrlPolicy.permissive` to keep the previous behavior, or a
  `RelayUrlPolicy` of your own.
- Decide a schedule request once instead of once per restart. A request the
  DVM turns down leaves no job behind, so nothing remembered the decision: the
  catch-up sweep decrypted it again on every start and sent its client the same
  `error` feedback, both for a failed validation and for a `job_id` already
  taken. The outcome now goes to the NDK decrypted payload sidecar, keyed by
  the request event id and the DVM pubkey, and is written only once the client
  has been told. A `CacheManager` without that sidecar keeps the previous
  behavior. A request that fails to decrypt is still retried, since a signer
  that is merely unreachable must not look like a permanent rejection.
- Bound the cache sweep that catches up on missed requests. It reloaded every
  `kind:5905` and `kind:5` the DVM had ever cached, on every sync tick, which
  never stops growing on a persistent cache. The sweep now starts at
  `cacheSweepFloor`, derived from the coverage the sync engine reports: the end
  of the coverage contiguous from the epoch, across every relay of the request,
  less the engine's `overlapMargin`. It falls back to the whole cache whenever
  a relay has a gap reaching back to the epoch, so a fresh, interrupted or
  newly added relay is still swept in full.

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
