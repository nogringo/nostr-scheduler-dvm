import 'dart:math';

import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// `created_at` floor for a sweep of the NDK cache, or null to sweep all of it.
///
/// The sweep catches up on what the live subscriptions missed, and the cache
/// keeps every request the DVM ever saw, so an unbounded sweep reloads all of
/// them on every sync tick. Only a period the sync engine may still fetch can
/// hold an event the sweep has never seen, and the engine plans from the epoch
/// up, since the DVM filters carry no `since`. The floor is therefore where
/// coverage contiguous from the epoch stops, taken across every relay of the
/// request, less [overlapMargin] because a pass reaches that much further back
/// than its gap to absorb clock skew and late deliveries.
///
/// Null while any relay has a gap reaching back to the epoch, which is what a
/// fresh, interrupted or newly added relay looks like: the whole cache is then
/// in play again.
int? cacheSweepFloor(
  Iterable<RelayFilterSyncState> states, {
  required Duration overlapMargin,
}) {
  int? floor;
  for (final state in states) {
    final end = _contiguousCoverageEnd(state.coverage);
    if (end == null) return null;
    floor = floor == null ? end : min(floor, end);
  }
  if (floor == null) return null;

  final seconds = floor - overlapMargin.inSeconds;
  return seconds > 0 ? seconds : null;
}

/// Where coverage contiguous from the epoch stops, or null when a gap reaches
/// back to the epoch. Ranges are normalised but only opportunistically merged,
/// so two touching ranges still count as one run.
int? _contiguousCoverageEnd(List<CoverageRange> coverage) {
  if (coverage.isEmpty) return null;

  final sorted = [...coverage]..sort((a, b) => a.from.compareTo(b.from));
  if (sorted.first.from.isAfter(_epoch)) return null;

  var end = sorted.first.to;
  for (final range in sorted.skip(1)) {
    if (range.from.isAfter(end)) break;
    if (range.to.isAfter(end)) end = range.to;
  }
  return end.millisecondsSinceEpoch ~/ 1000;
}
