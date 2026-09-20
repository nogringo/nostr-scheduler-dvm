import 'package:ndk/ndk.dart';
import 'package:nostr_scheduler_dvm/nostr_scheduler_dvm.dart';
import 'package:test/test.dart';

void main() {
  late List<String> due;
  late ScheduleRunner runner;

  setUp(() {
    due = [];
    runner = ScheduleRunner(
      clock: DateTime.now,
      onDue: (requestEventId) async => due.add(requestEventId),
    );
  });

  tearDown(() async => runner.dispose());

  test('runs a job that is already due', () async {
    runner.schedule(_job(scheduleAt: _nowSeconds() - 1));

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(due, ['request']);
  });

  test('does not run a job whose schedule_at overflows Duration', () async {
    runner.schedule(_job(scheduleAt: 10000000000000));

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(due, isEmpty);
  });
}

int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

DvmJob _job({required int scheduleAt}) {
  final now = _nowSeconds();
  return DvmJob(
    jobId: 'job',
    requestEventId: 'request',
    clientPubkey: 'client',
    dvmPubkey: 'dvm',
    scheduleAt: scheduleAt,
    targetEvent: Nip01Event(
      pubKey: 'client',
      kind: Nip01Event.kTextNodeKind,
      tags: [],
      content: 'target',
      createdAt: now,
    ),
    targetRelays: const ['wss://relay.example'],
    createdAt: now,
    updatedAt: now,
    status: DvmJobStatus.scheduled,
  );
}
