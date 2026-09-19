import 'dart:async';

import 'package:ndk/ndk.dart';
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

import 'dvm_job.dart';
import 'dvm_job_status.dart';
import 'feedback_publisher.dart';
import 'schedule_request_payload.dart';
import 'schedule_runner.dart';
import 'scheduler_dvm_config.dart';

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
  final Map<String, Nip01Event> _pendingDeletions = {};
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
    final requestTags = {
      '#p': [config.dvmPubkey],
    };

    final requests = await cache.loadEvents(
      kinds: [requestKind],
      tags: requestTags,
    );
    // NDK hides a request once its deletion is cached, yet a request cancelled
    // before we saw it still owes its client a cancelled feedback.
    final deletedRequests = await cache.loadHiddenEvents(
      kinds: [requestKind],
      tags: requestTags,
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
    );
    for (final event in deletions) {
      await _ingest(event, _handleDeletion);
    }
  }

  Future<void> _ingest(
    Nip01Event event,
    Future<void> Function(Nip01Event event) handler,
  ) async {
    if (!_started || !_ingestedEventIds.add(event.id)) return;
    await handler(event);
  }

  void _startSubscriptions() {
    final scheduleResponse = config.ndk.requests.subscription(
      filter: _scheduleRequestFilter,
      explicitRelays: _relays.requestRelays,
      cacheRead: false,
      cacheWrite: false,
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
      cacheWrite: false,
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

    final decrypted = await _decryptRequest(event);
    if (decrypted == null) return;

    final ScheduleRequestPayload payload;
    try {
      payload = await ScheduleRequestPayload.parseAndValidate(
        decrypted,
        eventVerifier: config.ndk.config.eventVerifier,
        maxScheduleAt: _nowSeconds() + config.maxScheduleAhead.inSeconds,
        maxRelays: config.maxRelaysPerJob,
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
      return;
    }

    final existing = await config.store.getJob(payload.jobId);
    if (existing != null) {
      if (existing.requestEventId != event.id) {
        await _sendFeedback(
          jobId: payload.jobId,
          clientPubkey: event.pubKey,
          status: 'error',
          message: 'job_id already exists',
        );
      }
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

    final pendingDeletion = _pendingDeletions.remove(event.id);
    if (pendingDeletion != null && pendingDeletion.pubKey == event.pubKey) {
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

  Future<void> _handleDeletion(Nip01Event event) async {
    final requestEventIds = event.getTags('e');
    for (final requestEventId in requestEventIds) {
      final job = await config.store.getJobByRequestEventId(requestEventId);
      if (job == null) {
        _pendingDeletions[requestEventId] = event;
        continue;
      }
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
      _runner.cancel(job.jobId);
      await config.store.putJob(cancelled);
      await _sendFeedback(
        jobId: job.jobId,
        clientPubkey: job.clientPubkey,
        status: 'cancelled',
        message: 'Job cancelled',
      );
    }
  }

  Future<void> _publishDueJob(String jobId) async {
    final job = await config.store.getJob(jobId);
    if (job == null || job.isTerminal) return;

    if (job.scheduleAt > _nowSeconds()) {
      _runner.schedule(job);
      return;
    }

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
    try {
      final response = config.ndk.broadcast.broadcast(
        nostrEvent: job.targetEvent,
        specificRelays: job.targetRelays,
        customSigner: config.signer,
        timeout: const Duration(seconds: 15),
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

  int _nowSeconds() => config.clock().millisecondsSinceEpoch ~/ 1000;
}

class _PublishResult {
  final bool success;
  final String message;

  const _PublishResult({required this.success, required this.message});
}
