@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broadcast_queue_shim_for_ndk/broadcast_queue_shim_for_ndk.dart';
import 'package:ndk/domain_layer/entities/nip_65.dart';
import 'package:ndk/domain_layer/entities/read_write_marker.dart';
import 'package:ndk/domain_layer/entities/user_relay_list.dart';
import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:ndk/shared/nips/nip01/key_pair.dart';
import 'package:nostr_scheduler_dvm/nostr_scheduler_dvm.dart';
import 'package:nostr_event_scheduler/nostr_event_scheduler.dart';
import 'package:sembast/sembast.dart' as sembast;
import 'package:sembast/sembast_io.dart' as sembast_io;
import 'package:sembast/sembast_memory.dart' as sembast_memory;
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';
import 'package:test/test.dart';

import 'support/mock_relay.dart';

void main() {
  late MockRelay relay;
  late KeyPair clientKey;
  late KeyPair dvmKey;
  late Ndk clientNdk;
  late Ndk dvmNdk;
  late OfflineBroadcast clientBroadcast;
  late EventScheduler clientScheduler;
  late SchedulerDvm dvm;
  late DvmJobStore dvmStore;
  final dbsToClose = <dynamic>[];
  final dvmsToDispose = <SchedulerDvm>[];
  final ndksToDestroy = <Ndk>[];
  final broadcastsToDispose = <OfflineBroadcast>[];
  final enginesToDispose = <SyncEngine>[];
  var syncDbCount = 0;

  Future<SyncEngine> startSyncEngine(Ndk ndk) async {
    final db = await sembast_memory.databaseFactoryMemory.openDatabase(
      'sync-${syncDbCount++}-${relay.url}.db',
    );
    dbsToClose.add(db);
    final engine = SyncEngine(ndk, db: db)..start();
    enginesToDispose.add(engine);
    return engine;
  }

  setUp(() async {
    relay = MockRelay(name: 'scheduler relay');

    clientKey = Bip340.generatePrivateKey();
    dvmKey = Bip340.generatePrivateKey();

    clientNdk = _createNdk(relay.url);
    dvmNdk = _createNdk(relay.url);
    ndksToDestroy.addAll([clientNdk, dvmNdk]);

    clientNdk.accounts.loginPrivateKey(
      pubkey: clientKey.publicKey,
      privkey: clientKey.privateKey!,
    );
    dvmNdk.accounts.loginPrivateKey(
      pubkey: dvmKey.publicKey,
      privkey: dvmKey.privateKey!,
    );

    final clientNip65 = _nip65For(clientKey, relay);
    final dvmNip65 = _nip65For(dvmKey, relay);
    final dvmMetadata = await _signedMetadata(dvmNdk, dvmKey);

    // The mock relay serves NIP-65 and metadata from these maps, not from the
    // events it stores.
    await relay.startServer(
      nip65s: {clientKey: clientNip65, dvmKey: dvmNip65},
      metadatas: {dvmKey.publicKey: dvmMetadata},
    );

    await _cacheNip65(clientNdk, clientNip65);
    await _cacheNip65(dvmNdk, dvmNip65);
    await dvmNdk.config.cache.saveEvent(dvmMetadata);

    final broadcastDb = await sembast_memory.databaseFactoryMemory.openDatabase(
      'broadcast-${relay.url}.db',
    );
    final schedulerDb = await sembast_memory.databaseFactoryMemory.openDatabase(
      'scheduler-${relay.url}.db',
    );
    dbsToClose.addAll([broadcastDb, schedulerDb]);

    clientBroadcast = OfflineBroadcast.withNdk(clientNdk, db: broadcastDb);
    clientBroadcast.start();
    broadcastsToDispose.add(clientBroadcast);

    clientScheduler = EventScheduler(
      ndk: clientNdk,
      broadcast: clientBroadcast,
      syncEngine: await startSyncEngine(clientNdk),
      db: schedulerDb,
    );
    await clientScheduler.startListening(pubkey: clientKey.publicKey);

    final dvmDb = await sembast_memory.databaseFactoryMemory.openDatabase(
      'dvm-${relay.url}.db',
    );
    dbsToClose.add(dvmDb);
    dvm = _createDvm(
      ndk: dvmNdk,
      syncEngine: await startSyncEngine(dvmNdk),
      database: dvmDb,
      bootstrapRelayUrl: relay.url,
    );
    dvmStore = dvm.config.store;
    dvmsToDispose.add(dvm);
    await dvm.start();
  });

  tearDown(() async {
    await clientScheduler.dispose();
    for (final dvm in dvmsToDispose.reversed) {
      await dvm.dispose();
    }
    dvmsToDispose.clear();
    for (final engine in enginesToDispose.reversed) {
      await engine.dispose();
    }
    enginesToDispose.clear();
    for (final broadcast in broadcastsToDispose.reversed) {
      await broadcast.dispose();
    }
    broadcastsToDispose.clear();
    for (final ndk in ndksToDestroy.reversed) {
      await ndk.destroy();
    }
    ndksToDestroy.clear();
    for (final db in dbsToClose.reversed) {
      await db.close();
    }
    dbsToClose.clear();
    await relay.stopServer();
  });

  test('resolves runtime relays from the DVM NIP-65 list', () {
    expect(dvm.relays.fromNip65, isTrue);
    expect(dvm.relays.requestRelays, contains(relay.url));
    expect(dvm.relays.feedbackRelays, contains(relay.url));
  });

  test(
    'uses NDK bootstrap relays when DVM bootstrap relays are omitted',
    () async {
      final db = await sembast_memory.databaseFactoryMemory.openDatabase(
        'bootstrap-${relay.url}.db',
      );
      dbsToClose.add(db);
      final config = SchedulerDvmConfig(
        ndk: dvmNdk,
        store: SembastDvmJobStore(db),
        syncEngine: await startSyncEngine(dvmNdk),
        announceNip89: false,
      );

      expect(config.bootstrapRelays, [relay.url]);
    },
  );

  test('falls back to the logged NDK account signer', () {
    expect(dvm.pubkey, dvmKey.publicKey);
    expect(dvmNdk.accounts.getLoggedAccount()!.pubkey, dvmKey.publicKey);
  });

  test('uses an explicit DVM signer with a shared app NDK instance', () async {
    final sharedNdk = _createNdk(relay.url);
    ndksToDestroy.add(sharedNdk);
    sharedNdk.accounts.loginPrivateKey(
      pubkey: clientKey.publicKey,
      privkey: clientKey.privateKey!,
    );

    final dvmSigner = const Bip340EventSignerFactory().create(
      privateKey: dvmKey.privateKey!,
      publicKey: dvmKey.publicKey,
    );
    addTearDown(dvmSigner.dispose);

    final sharedDb = await sembast_memory.databaseFactoryMemory.openDatabase(
      'shared-dvm-${relay.url}.db',
    );
    dbsToClose.add(sharedDb);
    final sharedDvm = _createDvm(
      ndk: sharedNdk,
      syncEngine: await startSyncEngine(sharedNdk),
      signer: dvmSigner,
      database: sharedDb,
      bootstrapRelayUrl: relay.url,
    );
    final sharedStore = sharedDvm.config.store;
    dvmsToDispose.add(sharedDvm);
    await sharedDvm.start();

    expect(sharedNdk.accounts.getLoggedAccount()!.pubkey, clientKey.publicKey);
    expect(sharedDvm.pubkey, dvmKey.publicKey);

    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'shared ndk dvm signer',
      DateTime.now().add(const Duration(minutes: 1)),
    );

    final job = await clientScheduler.schedule(
      target,
      [dvmKey.publicKey],
      pubkey: clientKey.publicKey,
      at: DateTime.now().add(const Duration(minutes: 1)),
      relays: [relay.url],
    );

    await _waitFor(() async {
      final stored = await sharedStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.scheduled;
    });
  });

  test('resolves NIP-89 profile from the DVM kind:0 metadata', () {
    expect(dvm.profile.fromMetadata, isTrue);
    expect(dvm.profile.name, 'Metadata Scheduler DVM');
    expect(dvm.profile.about, 'Metadata powered scheduler.');
  });

  test(
    'accepts a scheduler client request and emits private scheduled feedback',
    () async {
      final target = await _signedTextEvent(
        clientNdk,
        clientKey,
        'scheduled feedback',
        DateTime.now().add(const Duration(minutes: 1)),
      );

      final job = await clientScheduler.schedule(
        target,
        [dvmKey.publicKey],
        pubkey: clientKey.publicKey,
        at: DateTime.now().add(const Duration(minutes: 1)),
        relays: [relay.url],
      );

      await _waitFor(() async {
        final stored = await dvmStore.getJob(job.jobId);
        return stored?.status == DvmJobStatus.scheduled;
      });

      await _waitForFeedbackStatus(
        relay: relay,
        clientNdk: clientNdk,
        jobId: job.jobId,
        status: 'scheduled',
      );

      final feedback = _feedbackEvents(relay, job.jobId).first;
      expect(feedback.getFirstTag('p'), isNull);
      expect(feedback.pubKey, dvmKey.publicKey);
      expect(
        await Bip340EventVerifier(useIsolate: false).verify(feedback),
        isTrue,
      );
    },
  );

  test('publishes due events and reports published', () async {
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'publish me',
      DateTime.now(),
    );

    final job = await clientScheduler.schedule(
      target,
      [dvmKey.publicKey],
      pubkey: clientKey.publicKey,
      at: DateTime.now().add(const Duration(seconds: 1)),
      relays: [relay.url],
    );

    await _waitFor(
      () => relay.receivedEvents.any((event) => event.id == target.id),
    );
    await _waitFor(() async {
      final stored = await dvmStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.published;
    });
    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: job.jobId,
      status: 'published',
    );
  });

  test('cancels scheduled jobs before publication', () async {
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'do not publish',
      DateTime.now(),
    );

    final job = await clientScheduler.schedule(
      target,
      [dvmKey.publicKey],
      pubkey: clientKey.publicKey,
      at: DateTime.now().add(const Duration(seconds: 10)),
      relays: [relay.url],
    );

    await _waitFor(() async {
      final stored = await dvmStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.scheduled;
    });

    await clientScheduler.cancel(job.jobId, pubkey: clientKey.publicKey);

    await _waitFor(() async {
      final stored = await dvmStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.cancelled;
    });
    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: job.jobId,
      status: 'cancelled',
    );

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(relay.receivedEvents.any((event) => event.id == target.id), isFalse);
  });

  test('sends error feedback for invalid payloads', () async {
    const jobId =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final request = await _signedScheduleRequest(
      clientNdk: clientNdk,
      clientKey: clientKey,
      dvmPubkey: dvmKey.publicKey,
      payload: {
        'job_id': jobId,
        'schedule_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'signed_event': {
          'id': 'bad',
          'pubkey': clientKey.publicKey,
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'kind': 1,
          'tags': [],
          'content': 'invalid',
          'sig': 'bad',
        },
        'relays': [relay.url],
      },
    );

    await _broadcast(clientNdk, request, relay.url);

    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: jobId,
      status: 'error',
    );
    expect(await dvmStore.getJob(jobId), isNull);
  });

  test('sends error feedback for a schedule_at beyond the horizon', () async {
    const jobId =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'too far',
      DateTime.now(),
    );
    final request = await _signedScheduleRequest(
      clientNdk: clientNdk,
      clientKey: clientKey,
      dvmPubkey: dvmKey.publicKey,
      payload: {
        'job_id': jobId,
        'schedule_at': 10000000000000,
        'signed_event': {
          'id': target.id,
          'pubkey': target.pubKey,
          'created_at': target.createdAt,
          'kind': target.kind,
          'tags': target.tags,
          'content': target.content,
          'sig': target.sig,
        },
        'relays': [relay.url],
      },
    );

    await _broadcast(clientNdk, request, relay.url);

    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: jobId,
      status: 'error',
    );
    expect(await dvmStore.getJob(jobId), isNull);
  });

  test('sends error feedback for too many target relays', () async {
    const jobId =
        'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'too many relays',
      DateTime.now(),
    );
    final relays = List.generate(
      SchedulerDvmConfig.defaultMaxRelaysPerJob + 1,
      (index) => 'wss://relay$index.example',
    );
    final request = await _signedScheduleRequest(
      clientNdk: clientNdk,
      clientKey: clientKey,
      dvmPubkey: dvmKey.publicKey,
      payload: {
        'job_id': jobId,
        'schedule_at':
            DateTime.now()
                .add(const Duration(minutes: 1))
                .millisecondsSinceEpoch ~/
            1000,
        'signed_event': {
          'id': target.id,
          'pubkey': target.pubKey,
          'created_at': target.createdAt,
          'kind': target.kind,
          'tags': target.tags,
          'content': target.content,
          'sig': target.sig,
        },
        'relays': relays,
      },
    );

    await _broadcast(clientNdk, request, relay.url);

    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: jobId,
      status: 'error',
    );
    expect(await dvmStore.getJob(jobId), isNull);
  });

  test('is idempotent for repeated request events', () async {
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'idempotent',
      DateTime.now().add(const Duration(minutes: 1)),
    );

    final job = await clientScheduler.schedule(
      target,
      [dvmKey.publicKey],
      pubkey: clientKey.publicKey,
      at: DateTime.now().add(const Duration(minutes: 1)),
      relays: [relay.url],
    );

    await _waitFor(() async => (await dvmStore.listJobs()).length == 1);
    final requestEvent = relay.receivedEvents.firstWhere(
      (event) => event.kind == SchedulerDvm.requestKind,
    );
    relay.sendEvent(event: requestEvent, subId: 'scheduler-dvm-5905');

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final jobs = await dvmStore.listJobs();
    expect(jobs.where((stored) => stored.jobId == job.jobId), hasLength(1));
  });

  test('schedules requests synced into the NDK cache', () async {
    final request = await _validScheduleRequest(
      clientNdk: clientNdk,
      clientKey: clientKey,
      dvmPubkey: dvmKey.publicKey,
      relayUrl: relay.url,
      jobId: 'b' * 64,
    );
    await dvmNdk.config.cache.saveEvent(request);

    await dvm.resync();

    final stored = await dvmStore.getJob('b' * 64);
    expect(stored?.status, DvmJobStatus.scheduled);
    expect(stored?.requestEventId, request.id);
  });

  test('cancels a request whose deletion was synced with it', () async {
    final request = await _validScheduleRequest(
      clientNdk: clientNdk,
      clientKey: clientKey,
      dvmPubkey: dvmKey.publicKey,
      relayUrl: relay.url,
      jobId: 'c' * 64,
    );
    final deletion = await clientNdk.accounts.getLoggedAccount()!.signer.sign(
      Nip01Event(
        pubKey: clientKey.publicKey,
        kind: SchedulerDvm.deleteKind,
        tags: [
          ['e', request.id],
          ['k', '${SchedulerDvm.requestKind}'],
          ['p', dvmKey.publicKey],
        ],
        content: 'cancel',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    await dvmNdk.config.cache.saveEvent(request);
    await dvmNdk.config.cache.saveEvent(deletion);

    await dvm.resync();

    final stored = await dvmStore.getJob('c' * 64);
    expect(stored?.status, DvmJobStatus.cancelled);
    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: 'c' * 64,
      status: 'cancelled',
    );
  });

  test('ignores a deletion that does not tag the DVM', () async {
    final request = await _validScheduleRequest(
      clientNdk: clientNdk,
      clientKey: clientKey,
      dvmPubkey: dvmKey.publicKey,
      relayUrl: relay.url,
      jobId: 'e' * 64,
    );
    final deletion = await clientNdk.accounts.getLoggedAccount()!.signer.sign(
      Nip01Event(
        pubKey: clientKey.publicKey,
        kind: SchedulerDvm.deleteKind,
        tags: [
          ['e', request.id],
          ['k', '${SchedulerDvm.requestKind}'],
        ],
        content: 'cancel',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    await dvmNdk.config.cache.saveEvent(request);
    await dvmNdk.config.cache.saveEvent(deletion);

    await dvm.resync();

    final stored = await dvmStore.getJob('e' * 64);
    expect(stored?.status, DvmJobStatus.scheduled);
  });

  test('marks a job failed when every target relay fails', () async {
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'fail me',
      DateTime.now(),
    );

    final job = await clientScheduler.schedule(
      target,
      [dvmKey.publicKey],
      pubkey: clientKey.publicKey,
      at: DateTime.now().add(const Duration(seconds: 1)),
      relays: ['ws://127.0.0.1:59999'],
    );

    await _waitFor(() async {
      final stored = await dvmStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.failed;
    }, timeout: const Duration(seconds: 25));
    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: job.jobId,
      status: 'failed',
    );
  });

  test('publishes persisted jobs after restart', () async {
    final tempDir = await Directory.systemTemp.createTemp('scheduler-dvm-test');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    await dvm.dispose();
    dvmsToDispose.remove(dvm);
    await dvmNdk.destroy();
    ndksToDestroy.remove(dvmNdk);

    dvmNdk = _createNdk(relay.url);
    ndksToDestroy.add(dvmNdk);
    dvmNdk.accounts.loginPrivateKey(
      pubkey: dvmKey.publicKey,
      privkey: dvmKey.privateKey!,
    );

    final firstDb = await sembast_io.databaseFactoryIo.openDatabase(
      '${tempDir.path}/scheduler.db',
    );
    dbsToClose.add(firstDb);
    dvm = _createDvm(
      ndk: dvmNdk,
      syncEngine: await startSyncEngine(dvmNdk),
      database: firstDb,
      bootstrapRelayUrl: relay.url,
    );
    dvmStore = dvm.config.store;
    await dvm.start();

    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'after restart',
      DateTime.now(),
    );
    await clientScheduler.schedule(
      target,
      [dvmKey.publicKey],
      pubkey: clientKey.publicKey,
      at: DateTime.now().add(const Duration(seconds: 10)),
      relays: [relay.url],
    );

    await _waitFor(
      () async => (await dvmStore.listActiveJobs()).isNotEmpty,
      timeout: const Duration(seconds: 15),
    );
    await dvm.dispose();
    dbsToClose.remove(firstDb);
    await firstDb.close();
    await dvmNdk.destroy();
    ndksToDestroy.remove(dvmNdk);

    dvmNdk = _createNdk(relay.url);
    ndksToDestroy.add(dvmNdk);
    dvmNdk.accounts.loginPrivateKey(
      pubkey: dvmKey.publicKey,
      privkey: dvmKey.privateKey!,
    );
    final secondDb = await sembast_io.databaseFactoryIo.openDatabase(
      '${tempDir.path}/scheduler.db',
    );
    dbsToClose.add(secondDb);
    dvm = _createDvm(
      ndk: dvmNdk,
      syncEngine: await startSyncEngine(dvmNdk),
      database: secondDb,
      bootstrapRelayUrl: relay.url,
    );
    dvmStore = dvm.config.store;
    dvmsToDispose.add(dvm);
    await dvm.start();

    await _waitFor(
      () => relay.receivedEvents.any((event) => event.id == target.id),
      timeout: const Duration(seconds: 25),
    );
  });

  test('library sources do not import dart:io', () {
    final importsDartIo = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => file.readAsStringSync().contains("import 'dart:io'"))
        .map((file) => file.path)
        .toList();

    expect(importsDartIo, isEmpty);
  });
}

Ndk _createNdk(String relayUrl) {
  return Ndk(
    NdkConfig(
      eventVerifier: Bip340EventVerifier(useIsolate: false),
      cache: MemCacheManager(),
      bootstrapRelays: [relayUrl],
      fetchedRangesEnabled: true,
      defaultQueryTimeout: const Duration(seconds: 2),
      defaultBroadcastTimeout: const Duration(seconds: 2),
    ),
  );
}

SchedulerDvm _createDvm({
  required Ndk ndk,
  required SyncEngine syncEngine,
  EventSigner? signer,
  required sembast.Database database,
  required String bootstrapRelayUrl,
}) {
  return SchedulerDvm(
    SchedulerDvmConfig(
      ndk: ndk,
      signer: signer,
      store: SembastDvmJobStore(database),
      syncEngine: syncEngine,
      bootstrapRelays: [bootstrapRelayUrl],
      announceNip89: false,
    ),
  );
}

Nip65 _nip65For(KeyPair keyPair, MockRelay relay) {
  return Nip65(
    pubKey: keyPair.publicKey,
    relays: {relay.url: ReadWriteMarker.readWrite},
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
}

Future<void> _cacheNip65(Ndk ndk, Nip65 nip65) async {
  final signed = await ndk.accounts.getLoggedAccount()!.signer.sign(
    nip65.toEvent(),
  );
  await ndk.config.cache.saveEvent(signed);
  await ndk.config.cache.saveUserRelayList(UserRelayList.fromNip65(nip65));
}

Future<Nip01Event> _signedMetadata(Ndk ndk, KeyPair keyPair) {
  final metadata = Metadata(
    pubKey: keyPair.publicKey,
    name: 'Metadata Scheduler DVM',
    displayName: 'Display Scheduler DVM',
    about: 'Metadata powered scheduler.',
    updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  return ndk.accounts.getLoggedAccount()!.signer.sign(metadata.toEvent());
}

Future<Nip01Event> _signedTextEvent(
  Ndk ndk,
  KeyPair keyPair,
  String content,
  DateTime createdAt,
) {
  final event = Nip01Event(
    pubKey: keyPair.publicKey,
    kind: Nip01Event.kTextNodeKind,
    tags: [],
    content: content,
    createdAt: createdAt.millisecondsSinceEpoch ~/ 1000,
  );
  return ndk.accounts.getLoggedAccount()!.signer.sign(event);
}

Future<Nip01Event> _signedScheduleRequest({
  required Ndk clientNdk,
  required KeyPair clientKey,
  required String dvmPubkey,
  required Map<String, Object?> payload,
}) async {
  final encrypted = await clientNdk.accounts
      .getLoggedAccount()!
      .signer
      .encryptNip44(plaintext: jsonEncode(payload), recipientPubKey: dvmPubkey);
  final event = Nip01Event(
    pubKey: clientKey.publicKey,
    kind: SchedulerDvm.requestKind,
    tags: [
      ['p', dvmPubkey],
      ['encrypted'],
    ],
    content: encrypted!,
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  return clientNdk.accounts.getLoggedAccount()!.signer.sign(event);
}

Future<Nip01Event> _validScheduleRequest({
  required Ndk clientNdk,
  required KeyPair clientKey,
  required String dvmPubkey,
  required String relayUrl,
  required String jobId,
}) async {
  final scheduleAt = DateTime.now().add(const Duration(minutes: 1));
  final target = await _signedTextEvent(
    clientNdk,
    clientKey,
    'synced $jobId',
    scheduleAt,
  );
  return _signedScheduleRequest(
    clientNdk: clientNdk,
    clientKey: clientKey,
    dvmPubkey: dvmPubkey,
    payload: {
      'job_id': jobId,
      'schedule_at': scheduleAt.millisecondsSinceEpoch ~/ 1000,
      'signed_event': {
        'id': target.id,
        'pubkey': target.pubKey,
        'created_at': target.createdAt,
        'kind': target.kind,
        'tags': target.tags,
        'content': target.content,
        'sig': target.sig,
      },
      'relays': [relayUrl],
    },
  );
}

Future<void> _broadcast(Ndk ndk, Nip01Event event, String relayUrl) async {
  final response = ndk.broadcast.broadcast(
    nostrEvent: event,
    specificRelays: [relayUrl],
    timeout: const Duration(seconds: 2),
  );
  await response.broadcastDoneFuture.timeout(const Duration(seconds: 3));
}

List<Nip01Event> _feedbackEvents(MockRelay relay, String jobId) {
  return relay.receivedEvents
      .where(
        (event) =>
            event.kind == FeedbackPublisher.feedbackKind &&
            event.getFirstTag('r') == jobId,
      )
      .toList();
}

Future<void> _waitForFeedbackStatus({
  required MockRelay relay,
  required Ndk clientNdk,
  required String jobId,
  required String status,
}) {
  return _waitFor(() async {
    for (final event in _feedbackEvents(relay, jobId)) {
      final ephemeralPubkey = event.getFirstTag('ephemeral-pubkey');
      if (ephemeralPubkey == null) continue;
      final decrypted = await clientNdk.accounts
          .getLoggedAccount()!
          .signer
          .decryptNip44(
            ciphertext: event.content,
            senderPubKey: ephemeralPubkey,
          );
      if (decrypted == null) continue;
      final payload = jsonDecode(decrypted) as Map<String, dynamic>;
      if (payload['status'] == status) return true;
    }
    return false;
  });
}

Future<void> _waitFor(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('Condition not met after $timeout');
}
