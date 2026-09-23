// ignore_for_file: prefer_initializing_formals

import 'package:sembast/sembast.dart' as sembast;

import 'dvm_job.dart';

/// Where the DVM keeps its jobs. Implement it to use a database other than
/// Sembast.
abstract class DvmJobStore {
  /// Inserts the job, or replaces the one with the same
  /// [DvmJob.requestEventId].
  Future<void> putJob(DvmJob job);

  Future<DvmJob?> getJobByRequestEventId(String requestEventId);

  /// A `job_id` is a client-chosen label, unique per client and not globally.
  Future<DvmJob?> getJobByClientJobId({
    required String clientPubkey,
    required String jobId,
  });

  Future<List<DvmJob>> listJobs();

  /// The jobs still scheduled, which the DVM sets its timers from on start.
  Future<List<DvmJob>> listActiveJobs();

  /// Called when the DVM is disposed.
  Future<void> close();
}

/// A [DvmJobStore] that keeps jobs in a Sembast database.
class SembastDvmJobStore implements DvmJobStore {
  final sembast.Database _db;
  final sembast.StoreRef<String, Map<String, Object?>> _jobs;
  final bool _closeDatabase;

  late final Future<void> _rekeyed = _rekeyLegacyRecords();

  /// With `closeDatabase`, [close] closes the database too. Otherwise the
  /// caller closes it.
  SembastDvmJobStore(
    this._db, {
    bool closeDatabase = false,
    String storeName = 'scheduler_dvm_jobs',
  }) : _closeDatabase = closeDatabase,
       _jobs = sembast.stringMapStoreFactory.store(storeName);

  @override
  Future<void> putJob(DvmJob job) async {
    await _rekeyed;
    await _jobs.record(job.requestEventId).put(_db, job.toJson());
  }

  @override
  Future<DvmJob?> getJobByRequestEventId(String requestEventId) async {
    await _rekeyed;
    final json = await _jobs.record(requestEventId).get(_db);
    return json == null ? null : DvmJob.fromJson(json);
  }

  @override
  Future<DvmJob?> getJobByClientJobId({
    required String clientPubkey,
    required String jobId,
  }) async {
    await _rekeyed;
    final snapshots = await _jobs.find(
      _db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.equals('clientPubkey', clientPubkey),
          sembast.Filter.equals('jobId', jobId),
        ]),
        limit: 1,
      ),
    );
    if (snapshots.isEmpty) return null;
    return DvmJob.fromJson(snapshots.first.value);
  }

  @override
  Future<List<DvmJob>> listJobs() async {
    await _rekeyed;
    final snapshots = await _jobs.find(
      _db,
      finder: sembast.Finder(sortOrders: [sembast.SortOrder('scheduleAt')]),
    );
    return snapshots
        .map((snapshot) => DvmJob.fromJson(snapshot.value))
        .toList();
  }

  @override
  Future<List<DvmJob>> listActiveJobs() async {
    await _rekeyed;
    final snapshots = await _jobs.find(
      _db,
      finder: sembast.Finder(
        filter: sembast.Filter.equals('status', 'scheduled'),
        sortOrders: [sembast.SortOrder('scheduleAt')],
      ),
    );
    return snapshots
        .map((snapshot) => DvmJob.fromJson(snapshot.value))
        .toList();
  }

  /// Jobs written by 0.3.0 are keyed by their job id, which the record key no
  /// longer is; left as they are, they would never be found again.
  Future<void> _rekeyLegacyRecords() async {
    await _db.transaction((txn) async {
      for (final snapshot in await _jobs.find(txn)) {
        final requestEventId = snapshot.value['requestEventId'];
        if (requestEventId is! String || requestEventId == snapshot.key) {
          continue;
        }
        await _jobs.record(requestEventId).put(txn, snapshot.value);
        await _jobs.record(snapshot.key).delete(txn);
      }
    });
  }

  @override
  Future<void> close() async {
    if (_closeDatabase) {
      await _db.close();
    }
  }
}
