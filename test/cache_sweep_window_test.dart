import 'package:nostr_scheduler_dvm/nostr_scheduler_dvm.dart';
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';
import 'package:test/test.dart';

const overlap = Duration(days: 1);
final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime at(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

RelayFilterSyncState state(
  List<(DateTime, DateTime)> ranges, {
  String relayUrl = 'wss://relay.example',
}) {
  return RelayFilterSyncState(
    relayUrl: relayUrl,
    filterFingerprint: 'fingerprint',
    coverage: [
      for (final (from, to) in ranges)
        CoverageRange(from: from, to: to, completedAt: to),
    ],
  );
}

void main() {
  group('cacheSweepFloor', () {
    test('sweeps everything when no relay has any coverage', () {
      expect(cacheSweepFloor(const [], overlapMargin: overlap), isNull);
      expect(cacheSweepFloor([state([])], overlapMargin: overlap), isNull);
    });

    test('sweeps everything while coverage does not start at the epoch', () {
      final states = [
        state([(at(600000), at(900000))]),
      ];
      expect(cacheSweepFloor(states, overlapMargin: overlap), isNull);
    });

    test('floors at the first gap above the epoch', () {
      final states = [
        state([(epoch, at(300000)), (at(600000), at(900000))]),
      ];
      // The run from the epoch stops at 300000, so the floor sits there.
      expect(
        cacheSweepFloor(states, overlapMargin: overlap),
        300000 - overlap.inSeconds,
      );
    });

    test('floors at the end of coverage contiguous from the epoch', () {
      final states = [
        state([(epoch, at(900000))]),
      ];
      expect(
        cacheSweepFloor(states, overlapMargin: overlap),
        900000 - overlap.inSeconds,
      );
    });

    test('treats touching ranges as one run', () {
      final states = [
        state([(epoch, at(300000)), (at(300000), at(900000))]),
      ];
      expect(
        cacheSweepFloor(states, overlapMargin: overlap),
        900000 - overlap.inSeconds,
      );
    });

    test('takes the lowest floor across relays', () {
      final states = [
        state([(epoch, at(900000))], relayUrl: 'wss://ahead.example'),
        state([(epoch, at(400000))], relayUrl: 'wss://behind.example'),
      ];
      expect(
        cacheSweepFloor(states, overlapMargin: overlap),
        400000 - overlap.inSeconds,
      );
    });

    test('sweeps everything when one relay of several has a gap', () {
      final states = [
        state([(epoch, at(900000))], relayUrl: 'wss://ahead.example'),
        state([(at(600000), at(900000))], relayUrl: 'wss://fresh.example'),
      ];
      expect(cacheSweepFloor(states, overlapMargin: overlap), isNull);
    });

    test('sweeps everything when the overlap reaches under the epoch', () {
      final states = [
        state([(epoch, at(3600))]),
      ];
      expect(cacheSweepFloor(states, overlapMargin: overlap), isNull);
    });

    test('ignores unsorted coverage order', () {
      final states = [
        state([(at(300000), at(900000)), (epoch, at(300000))]),
      ];
      expect(
        cacheSweepFloor(states, overlapMargin: overlap),
        900000 - overlap.inSeconds,
      );
    });
  });
}
