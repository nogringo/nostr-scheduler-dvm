import 'package:ndk/ndk.dart';
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

import 'dvm_job_store.dart';

typedef DvmClock = DateTime Function();

class SchedulerDvmRelays {
  final List<String> bootstrapRelays;
  final List<String> readRelays;
  final List<String> writeRelays;
  final bool fromNip65;

  SchedulerDvmRelays({
    required Iterable<String> bootstrapRelays,
    required Iterable<String> readRelays,
    required Iterable<String> writeRelays,
    required this.fromNip65,
  }) : bootstrapRelays = _cleanRelays(bootstrapRelays),
       readRelays = _cleanRelays(readRelays),
       writeRelays = _cleanRelays(writeRelays);

  List<String> get feedbackRelays => writeRelays.isEmpty
      ? (readRelays.isEmpty ? bootstrapRelays : readRelays)
      : writeRelays;

  List<String> get requestRelays => readRelays.isEmpty
      ? (writeRelays.isEmpty ? bootstrapRelays : writeRelays)
      : readRelays;

  List<String> get allRuntimeRelays {
    return {...requestRelays, ...feedbackRelays}.toList();
  }
}

class SchedulerDvmProfile {
  final String name;
  final String about;
  final bool fromMetadata;

  const SchedulerDvmProfile({
    required this.name,
    required this.about,
    required this.fromMetadata,
  });
}

class SchedulerDvmConfig {
  static const String defaultName = 'Scheduler DVM';
  static const String defaultAbout = 'Schedule any signed Nostr event.';
  static const Duration defaultMaxScheduleAhead = Duration(days: 10 * 365);

  final Ndk ndk;
  final EventSigner? _configuredSigner;
  final DvmJobStore store;

  /// Keeps schedule requests and cancellations synced into the NDK cache, so
  /// events published while the DVM was offline are not missed. It must run on
  /// [ndk], whose cache should be persistent. Caller-owned: start it, and
  /// dispose it after the DVM.
  final SyncEngine syncEngine;

  /// Relay URLs used as the discovery fallback for the Scheduler DVM.
  ///
  /// On startup the DVM first tries to resolve its own NIP-65 relay list from
  /// NDK. These relays are used to perform that lookup, and are also used as
  /// the runtime request/feedback relays when no NIP-65 list is found. If this
  /// is empty, the package falls back to `ndk.config.bootstrapRelays`.
  final List<String> bootstrapRelays;

  final String? name;
  final String? about;
  final bool announceNip89;

  /// Requests whose `schedule_at` is further ahead than this are rejected.
  final Duration maxScheduleAhead;
  final DvmClock clock;
  EventSigner? _resolvedSigner;

  SchedulerDvmConfig({
    required this.ndk,
    EventSigner? signer,
    required this.store,
    required this.syncEngine,

    /// Relay URLs used to discover the DVM's NIP-65 relay list.
    ///
    /// If omitted, `ndk.config.bootstrapRelays` is used.
    Iterable<String> bootstrapRelays = const [],
    this.name,
    this.about,
    this.announceNip89 = true,
    this.maxScheduleAhead = defaultMaxScheduleAhead,
    DvmClock? clock,
  }) : bootstrapRelays = _resolveBootstrapRelays(ndk, bootstrapRelays),
       _configuredSigner = signer,
       clock = clock ?? DateTime.now;

  EventSigner get signer {
    final resolved =
        _resolvedSigner ??
        _configuredSigner ??
        ndk.accounts.getLoggedAccount()?.signer;
    if (resolved == null || !resolved.canSign()) {
      throw StateError(
        'SchedulerDvmConfig requires either signer or a logged NDK account '
        'signer that can sign as the Scheduler DVM.',
      );
    }
    _resolvedSigner = resolved;
    return resolved;
  }

  String get dvmPubkey => signer.getPublicKey();

  Future<SchedulerDvmRelays> resolveRelays({bool forceRefresh = true}) async {
    final relayList = await ndk.userRelayLists.getSingleUserRelayList(
      dvmPubkey,
      forceRefresh: forceRefresh,
    );
    if (relayList == null || relayList.relays.isEmpty) {
      return SchedulerDvmRelays(
        bootstrapRelays: bootstrapRelays,
        readRelays: bootstrapRelays,
        writeRelays: bootstrapRelays,
        fromNip65: false,
      );
    }

    final readRelays = relayList.readUrls.toList();
    final writeRelays = relayList.writeUrls.toList();
    return SchedulerDvmRelays(
      bootstrapRelays: bootstrapRelays,
      readRelays: readRelays.isEmpty ? bootstrapRelays : readRelays,
      writeRelays: writeRelays.isEmpty ? bootstrapRelays : writeRelays,
      fromNip65: true,
    );
  }

  Future<SchedulerDvmProfile> resolveProfile(SchedulerDvmRelays relays) async {
    Metadata? metadata;
    try {
      final response = ndk.requests.query(
        filter: Filter(kinds: [Metadata.kKind], authors: [dvmPubkey], limit: 1),
        explicitRelays: relays.requestRelays,
      );
      await for (final event in response.stream) {
        final parsed = Metadata.fromEvent(event);
        if (metadata == null ||
            metadata.updatedAt == null ||
            (parsed.updatedAt ?? 0) > metadata.updatedAt!) {
          metadata = parsed;
        }
      }
    } catch (_) {
      metadata = await ndk.config.cache.loadMetadata(dvmPubkey);
    }
    metadata ??= await ndk.config.cache.loadMetadata(dvmPubkey);

    final metadataName = _firstNonBlank([
      metadata?.name,
      metadata?.displayName,
    ]);
    final metadataAbout = _firstNonBlank([metadata?.about]);

    return SchedulerDvmProfile(
      name: metadataName ?? _nonBlank(name) ?? defaultName,
      about: metadataAbout ?? _nonBlank(about) ?? defaultAbout,
      fromMetadata: metadataName != null || metadataAbout != null,
    );
  }
}

List<String> _cleanRelays(Iterable<String> relays) {
  return List.unmodifiable(
    relays.map((relay) => relay.trim()).where((relay) => relay.isNotEmpty),
  );
}

List<String> _resolveBootstrapRelays(Ndk ndk, Iterable<String> relays) {
  final configured = _cleanRelays(relays);
  if (configured.isNotEmpty) return configured;
  return _cleanRelays(ndk.config.bootstrapRelays);
}

String? _firstNonBlank(Iterable<String?> values) {
  for (final value in values) {
    final cleaned = _nonBlank(value);
    if (cleaned != null) return cleaned;
  }
  return null;
}

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
