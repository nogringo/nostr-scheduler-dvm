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
