import 'dart:async';

import 'package:ndk/ndk.dart';
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

import 'cache_sweep_window.dart';
import 'dvm_job.dart';
import 'dvm_job_status.dart';
import 'feedback_publisher.dart';
import 'schedule_request_payload.dart';
import 'schedule_runner.dart';
import 'scheduler_dvm_config.dart';
import 'target_relay_auth.dart';

/// Publishes each event scheduled with the DVM when it falls due, unless its
/// client cancels it first.
class SchedulerDvm {
  static const int requestKind = 5905;
  static const int deleteKind = 5;

  final SchedulerDvmConfig config;
  late final FeedbackPublisher _feedbackPublisher;
  late final ScheduleRunner _runner;
  late SchedulerDvmRelays _relays;
  late SchedulerDvmProfile _profile;

  final List<NdkResponse> _responses = [];
  final List<StreamSubscription<Nip01Event>> _subscriptions = [];
  final Set<String> _ingestedEventIds = {};

  SyncHandle? _syncHandle;
  StreamSubscription<SyncRequestStatus>? _syncStatus;

  bool _started = false;

  SchedulerDvm(this.config) {
    _relays = SchedulerDvmRelays(
      bootstrapRelays: config.bootstrapRelays,
      readRelays: config.bootstrapRelays,
      writeRelays: config.bootstrapRelays,
      fromNip65: false,
    );
    _profile = SchedulerDvmProfile(
      name: config.name ?? SchedulerDvmConfig.defaultName,
      about: config.about ?? SchedulerDvmConfig.defaultAbout,
      fromMetadata: false,
    );
    _feedbackPublisher = FeedbackPublisher(config, _profile, _relays);
    _runner = ScheduleRunner(clock: config.clock, onDue: _publishDueJob);
  }

  String get pubkey => config.dvmPubkey;

  SchedulerDvmRelays get relays => _relays;

  SchedulerDvmProfile get profile => _profile;

  /// Subscribes to requests and cancellations, catches up on those published
  /// while the DVM was stopped, and restores the timers of the stored jobs.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    await refreshRelays();
    await refreshProfile();
    _startSubscriptions();
    await resync();

    for (final job in await config.store.listActiveJobs()) {
      _runner.schedule(job);
    }

    if (config.announceNip89) {
      await _feedbackPublisher.publishDiscovery();
    }
  }

  Future<SchedulerDvmRelays> refreshRelays() async {
    _relays = await config.resolveRelays(forceRefresh: true);
    _feedbackPublisher.updateRelays(_relays);
    if (_started) await _watchSync();
    return _relays;
  }

  Future<SchedulerDvmProfile> refreshProfile() async {
    _profile = await config.resolveProfile(_relays);
    _feedbackPublisher.updateProfile(_profile);
    return _profile;
  }

  Future<void> resync() async {
    final handle = _syncHandle;
    if (handle == null) return;
    await config.syncEngine.refresh(handle);
    await _ingestSynced();
  }

  /// Stops serving requests. Unlike [dispose], leaves
  /// [SchedulerDvmConfig.store] open.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    await _syncStatus?.cancel();
    _syncStatus = null;
    final handle = _syncHandle;
    if (handle != null) config.syncEngine.release(handle);
    _syncHandle = null;

    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    for (final response in _responses) {
      await config.ndk.requests.closeSubscription(response.requestId);
    }
    _responses.clear();

    await _runner.dispose();
  }

  /// Stops the DVM and closes [SchedulerDvmConfig.store].
  Future<void> dispose() async {
    await stop();
    await config.store.close();
  }

  Filter get _scheduleRequestFilter =>
      Filter(kinds: [requestKind], pTags: [config.dvmPubkey]);

  Filter get _deletionFilter => Filter(
    kinds: [deleteKind],
    tags: {
      '#k': ['$requestKind'],
      '#p': [config.dvmPubkey],
    },
  );

  Future<void> _watchSync() async {
    final previous = _syncHandle;
    await _syncStatus?.cancel();

    final handle = config.syncEngine.ensure(
      SyncRequest(
        filters: [_scheduleRequestFilter, _deletionFilter],
        relays: _relays.requestRelays,
      ),
    );
    _syncHandle = handle;
    _syncStatus = config.syncEngine
        .watchStatus(handle)
        .where((status) => status.phase == SyncRequestPhase.synced)
        .listen((_) => unawaited(_ingestSynced()));

    if (previous != null) config.syncEngine.release(previous);
  }

  Future<void> _ingestSynced() async {
    final cache = config.ndk.config.cache;
    final since = _sweepFloor;
    final requestTags = {
      '#p': [config.dvmPubkey],
    };

    final requests = await cache.loadEvents(
      kinds: [requestKind],
      tags: requestTags,
      since: since,
    );
    // NDK hides a request once its deletion is cached, yet a request cancelled
    // before we saw it still owes its client a cancelled feedback.
    final deletedRequests = await cache.loadHiddenEvents(
      kinds: [requestKind],
      tags: requestTags,
      since: since,
      reasons: {HiddenEventReason.deleted},
    );
    for (final event in [
      ...requests,
      ...deletedRequests.map((hidden) => hidden.event),
    ]) {
      await _ingest(event, _handleScheduleRequest);
    }

    final deletions = await cache.loadEvents(
      kinds: [deleteKind],
      tags: _deletionFilter.tags,
      since: since,
    );
    for (final event in deletions) {
      await _ingest(event, _handleDeletion);
    }
  }

  /// No `limit` goes with this: on some backends it is pushed into the query
  /// ahead of the visibility rules, which would drop requests silently.
  int? get _sweepFloor {
    final handle = _syncHandle;
    if (handle == null) return null;

    return cacheSweepFloor(
      config.syncEngine.status(handle).relayStates,
      overlapMargin: config.syncEngine.overlapMargin,
    );
  }

  Future<void> _ingest(
    Nip01Event event,
    Future<void> Function(Nip01Event event) handler,
  ) async {
    if (!_started || !_rememberIngested(event.id)) return;
    await handler(event);
  }

  /// Only has to catch a redelivery close in time: the job store and the
  /// decrypted payload sidecar already make a later one idempotent, so the
  /// oldest id is cheap to forget once the set is full.
  bool _rememberIngested(String eventId) {
    if (!_ingestedEventIds.add(eventId)) return false;
    if (_ingestedEventIds.length > config.maxRememberedEvents) {
      _ingestedEventIds.remove(_ingestedEventIds.first);
    }
    return true;
  }

  void _startSubscriptions() {
    final scheduleResponse = config.ndk.requests.subscription(
      filter: _scheduleRequestFilter,
      explicitRelays: _relays.requestRelays,
      cacheRead: false,
      cacheWrite: true,
    );
    _responses.add(scheduleResponse);
    _subscriptions.add(
      scheduleResponse.stream.listen(
        (event) => unawaited(_ingest(event, _handleScheduleRequest)),
      ),
    );

    final deletionResponse = config.ndk.requests.subscription(
      filter: _deletionFilter,
      explicitRelays: _relays.requestRelays,
      cacheRead: false,
      cacheWrite: true,
    );
    _responses.add(deletionResponse);
    _subscriptions.add(
      deletionResponse.stream.listen(
        (event) => unawaited(_ingest(event, _handleDeletion)),
      ),
    );
  }

  Future<void> _handleScheduleRequest(Nip01Event event) async {
    if (!_isScheduleRequestForThisDvm(event)) return;
    if (await config.store.getJobByRequestEventId(event.id) != null) return;
    if (await _isDecided(event.id)) return;

    final decrypted = await _decryptRequest(event);
    if (decrypted == null) return;

    final ScheduleRequestPayload payload;
    try {
      payload = await ScheduleRequestPayload.parseAndValidate(
        decrypted,
        eventVerifier: config.ndk.config.eventVerifier,
        maxScheduleAt: _nowSeconds() + config.maxScheduleAhead.inSeconds,
        maxRelays: config.maxRelaysPerJob,
        relayPolicy: config.targetRelayPolicy,
      );
    } on PayloadValidationException catch (error) {
      if (error.jobId != null) {
        await _sendFeedback(
          jobId: error.jobId!,
          clientPubkey: event.pubKey,
          status: 'error',
          message: error.message,
        );
      }
      await _markDecided(event, decrypted);
      return;
    }

    if (_isStale(payload.scheduleAt)) {
      await _markDecided(event, decrypted);
      return;
    }

    final existing = await config.store.getJobByClientJobId(
      clientPubkey: event.pubKey,
      jobId: payload.jobId,
    );
    if (existing != null) {
      await _sendFeedback(
        jobId: payload.jobId,
        clientPubkey: event.pubKey,
        status: 'error',
        message: 'job_id already exists',
      );
      await _markDecided(event, decrypted);
      return;
    }

    final now = _nowSeconds();
    var job = DvmJob(
      jobId: payload.jobId,
      requestEventId: event.id,
      clientPubkey: event.pubKey,
      dvmPubkey: config.dvmPubkey,
      scheduleAt: payload.scheduleAt,
      targetEvent: payload.signedEvent,
      targetRelays: payload.relays,
      createdAt: now,
      updatedAt: now,
      status: DvmJobStatus.scheduled,
    );

    if (await _isCancelledOnArrival(event)) {
      job = job.copyWith(
        status: DvmJobStatus.cancelled,
        updatedAt: now,
        cancelledAt: now,
        lastMessage: 'Cancelled before scheduling',
      );
      await config.store.putJob(job);
      await _sendFeedback(
        jobId: job.jobId,
        clientPubkey: job.clientPubkey,
        status: 'cancelled',
        message: 'Job cancelled',
      );
      return;
    }

    await config.store.putJob(job);
    await _sendFeedback(
      jobId: job.jobId,
      clientPubkey: job.clientPubkey,
      status: 'scheduled',
      message: 'Job accepted',
    );
    _runner.schedule(job);
  }

  /// A request the DVM turned down leaves no job behind, so the decrypted
  /// payload sidecar is what carries that decision across a restart. Without
  /// it the sweep decrypts, rejects and tells the client all over again.
  Future<bool> _isDecided(String requestEventId) async {
    try {
      final record = await config.ndk.config.cache
          .loadDecryptedEventPayloadRecord(
            eventId: requestEventId,
            viewerPubKey: config.dvmPubkey,
          );
      return record?.status == DecryptedPayloadStatus.ready;
    } catch (_) {
      return false;
    }
  }

  /// Written once the client has been told, never before: a crash in between
  /// leaves the request to be decided again rather than silently dropped.
  Future<void> _markDecided(Nip01Event request, String plaintext) async {
    final now = _nowSeconds();
    try {
      await config.ndk.config.cache.saveDecryptedEventPayloadRecord(
        DecryptedEventPayloadRecord(
          eventId: request.id,
          viewerPubKey: config.dvmPubkey,
          scheme: DecryptedPayloadScheme.nip44,
          status: DecryptedPayloadStatus.ready,
          plaintextContent: plaintext,
          createdAt: now,
          updatedAt: now,
          decryptedAt: now,
          sourceEventPubKey: request.pubKey,
          sourceEventKind: request.kind,
        ),
      );
    } catch (_) {
      // A cache without the sidecar just decides again on the next restart.
    }
  }

  Future<String?> _decryptRequest(Nip01Event event) async {
    try {
      return await config.signer.decryptNip44(
        ciphertext: event.content,
        senderPubKey: event.pubKey,
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether the client cancelled [request] before the DVM got to it. NDK
  /// hides such a request from the live stream once the cancellation is cached,
  /// so the sweep is what brings it here, and its client is still owed a
  /// cancelled feedback.
  Future<bool> _isCancelledOnArrival(Nip01Event request) async {
    try {
      final deletions = await config.ndk.config.cache.loadEvents(
        kinds: [deleteKind],
        tags: {
          ...?_deletionFilter.tags,
          '#e': [request.id],
        },
      );
      return deletions.any((deletion) => deletion.pubKey == request.pubKey);
    } catch (_) {
      // Without the lookup the job is created, and the deletion pass of the
      // sweep cancels it right after.
      return false;
    }
  }

  Future<void> _handleDeletion(Nip01Event event) async {
    final requestEventIds = event.getTags('e');
    for (final requestEventId in requestEventIds) {
      final job = await config.store.getJobByRequestEventId(requestEventId);
      // A cancellation naming a request the DVM has not seen needs nothing
      // kept: the request looks it up itself when it lands.
      if (job == null) continue;
      if (event.pubKey != job.clientPubkey) continue;
      if (job.status == DvmJobStatus.cancelled) continue;

      if (job.isTerminal) {
        await _sendFeedback(
          jobId: job.jobId,
          clientPubkey: job.clientPubkey,
          status: 'error',
          message: 'Job is already ${job.status.name}',
        );
        continue;
      }

      final now = _nowSeconds();
      final cancelled = job.copyWith(
        status: DvmJobStatus.cancelled,
        updatedAt: now,
        cancelledAt: now,
        lastMessage: 'Job cancelled',
      );
      _runner.cancel(job.requestEventId);
      await config.store.putJob(cancelled);
      await _sendFeedback(
        jobId: job.jobId,
        clientPubkey: job.clientPubkey,
        status: 'cancelled',
        message: 'Job cancelled',
      );
    }
  }

  Future<void> _publishDueJob(String requestEventId) async {
    final job = await config.store.getJobByRequestEventId(requestEventId);
    if (job == null || job.isTerminal) return;

    if (job.scheduleAt > _nowSeconds()) {
      _runner.schedule(job);
      return;
    }
    if (_isStale(job.scheduleAt)) return;

    final publishResult = await _publishTargetEvent(job);
    final now = _nowSeconds();
    final status = publishResult.success
        ? DvmJobStatus.published
        : DvmJobStatus.failed;
    final updated = job.copyWith(
      status: status,
      updatedAt: now,
      publishedAt: publishResult.success ? now : null,
      lastMessage: publishResult.message,
    );

    await config.store.putJob(updated);
    await _sendFeedback(
      jobId: updated.jobId,
      clientPubkey: updated.clientPubkey,
      status: updated.status.name,
      message: publishResult.message,
    );
  }

  Future<_PublishResult> _publishTargetEvent(DvmJob job) async {
    final auth = _targetRelayAuth();
    try {
      final response = config.ndk.broadcast.broadcast(
        nostrEvent: job.targetEvent,
        specificRelays: job.targetRelays,
        customSigner: config.signer,
        timeout: const Duration(seconds: 15),
        auth: auth,
      );
      final results = await response.broadcastDoneFuture.timeout(
        const Duration(seconds: 16),
      );
      final successCount = results
          .where((relayResponse) => relayResponse.broadcastSuccessful)
          .length;
      if (successCount > 0) {
        return _PublishResult(
          success: true,
          message:
              'Published to $successCount/${job.targetRelays.length} relays',
        );
      }

      final errors = results
          .where((relayResponse) => relayResponse.msg.isNotEmpty)
          .map(
            (relayResponse) =>
                '${relayResponse.relayUrl}: '
                '${relayResponse.msg}',
          )
          .join('; ');
      return _PublishResult(
        success: false,
        message: errors.isEmpty ? 'All target relays failed' : errors,
      );
    } catch (error) {
      return _PublishResult(success: false, message: 'Publish failed: $error');
    } finally {
      await _closeEphemeralAuthConnections(auth, job.targetRelays);
    }
  }

  /// Which identity a target relay asking for NIP-42 is answered with.
  ///
  /// Always [AuthPolicy.allow]: the event goes out on the anonymous connection,
  /// and only a relay that refuses it there ever sees an identity.
  AuthPolicy _targetRelayAuth() {
    switch (config.targetRelayAuth) {
      case TargetRelayAuth.never:
        return const AuthPolicy.never();
      case TargetRelayAuth.dvm:
        return AuthPolicy.allow(_dvmAccount());
      case TargetRelayAuth.ephemeral:
        return AuthPolicy.allow(_ephemeralAccount());
    }
  }

  Account _dvmAccount() {
    final registered = config.ndk.accounts.accounts[config.dvmPubkey];
    if (registered != null && registered.signer.canSign()) return registered;
    return Account(
      type: AccountType.privateKey,
      pubkey: config.dvmPubkey,
      signer: config.signer,
    );
  }

  Account _ephemeralAccount() {
    final signer = const Bip340EventSignerFactory().createWithNewKeyPair();
    return Account(
      type: AccountType.privateKey,
      pubkey: signer.getPublicKey(),
      signer: signer,
    );
  }

  /// An ephemeral key signs one publish, so the connection it opened is not
  /// kept either: reusing it would tie the next job to this one, and a busy DVM
  /// would hold a socket per job.
  Future<void> _closeEphemeralAuthConnections(
    AuthPolicy auth,
    Iterable<String> relayUrls,
  ) async {
    if (config.targetRelayAuth != TargetRelayAuth.ephemeral) return;
    final pubkey = auth.account?.pubkey;
    if (pubkey == null) return;
    for (final url in relayUrls) {
      await config.ndk.relays.closeConnection(
        RelayConnectionKey.authenticated(url, pubkey),
      );
    }
  }

  Future<void> _sendFeedback({
    required String jobId,
    required String clientPubkey,
    required String status,
    String? message,
  }) async {
    try {
      await _feedbackPublisher.publishFeedback(
        jobId: jobId,
        clientPubkey: clientPubkey,
        status: status,
        message: message,
      );
    } catch (_) {
      // Feedback best effort; durable job state is already persisted.
    }
  }

  bool _isScheduleRequestForThisDvm(Nip01Event event) {
    if (event.kind != requestKind) return false;
    if (event.getFirstTag('p') != config.dvmPubkey) return false;
    return event.tags.any((tag) => tag.length == 1 && tag.first == 'encrypted');
  }

  bool _isStale(int scheduleAt) =>
      scheduleAt < _nowSeconds() - config.maxScheduleBehind.inSeconds;

  int _nowSeconds() => config.clock().millisecondsSinceEpoch ~/ 1000;
}

class _PublishResult {
  final bool success;
  final String message;

  const _PublishResult({required this.success, required this.message});
}
