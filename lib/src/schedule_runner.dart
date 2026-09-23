// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'dvm_job.dart';
import 'scheduler_dvm_config.dart';

/// Called with the request event id of a job whose `schedule_at` has come.
/// Errors it throws are ignored.
typedef DueJobHandler = Future<void> Function(String requestEventId);

/// Calls a [DueJobHandler] as each job falls due. Its timers live in memory,
/// so jobs must be scheduled again after a restart.
class ScheduleRunner {
  /// Longer waits are chained, since a far `schedule_at` overflows `Duration`.
  static const int maxTimerDelaySeconds = 24 * 60 * 60;

  final DvmClock _clock;
  final DueJobHandler _onDue;
  final Map<String, Timer> _timers = {};

  ScheduleRunner({required DvmClock clock, required DueJobHandler onDue})
    : _clock = clock,
      _onDue = onDue;

  /// Replaces the job's pending timer. A due job runs at once, a finished one
  /// not at all.
  void schedule(DvmJob job) {
    cancel(job.requestEventId);
    if (job.isTerminal) return;

    final now = _clock().millisecondsSinceEpoch ~/ 1000;
    final delaySeconds = job.scheduleAt - now;
    if (delaySeconds <= 0) {
      unawaited(_run(job.requestEventId));
      return;
    }

    final timerSeconds = min(delaySeconds, maxTimerDelaySeconds);
    _timers[job.requestEventId] = Timer(Duration(seconds: timerSeconds), () {
      _timers.remove(job.requestEventId);
      unawaited(_run(job.requestEventId));
    });
  }

  void cancel(String requestEventId) {
    _timers.remove(requestEventId)?.cancel();
  }

  Future<void> dispose() async {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _run(String requestEventId) async {
    try {
      await _onDue(requestEventId);
    } catch (_) {
      // The caller owns durable job state and status feedback.
    }
  }
}
