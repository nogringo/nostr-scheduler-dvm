import 'package:ndk/ndk.dart';
import 'package:nostr_scheduler_dvm/nostr_scheduler_dvm.dart';
import 'package:test/test.dart';

void main() {
  group('RelayUrlPolicy.public', () {
    const policy = RelayUrlPolicy.public;

    test('accepts public wss relays', () {
      for (final url in [
        'wss://relay.damus.io',
        'wss://relay.example.com/',
        'wss://relay.example.com:7777',
        'wss://192.0.2.10',
      ]) {
        expect(policy.rejectionReason(url), isNull, reason: url);
      }
    });

    test('rejects anything but wss', () {
      for (final url in [
        'ws://relay.example.com',
        'http://relay.example.com',
        'https://relay.example.com',
        'file:///etc/passwd',
        'relay.example.com',
        'not a url',
        '',
      ]) {
        expect(policy.rejectionReason(url), isNotNull, reason: url);
      }
    });

    test('rejects loopback, private and link-local hosts', () {
      for (final url in [
        'wss://localhost',
        'wss://scheduler.localhost',
        'wss://127.0.0.1:4869',
        'wss://0.0.0.0',
        'wss://10.1.2.3',
        'wss://172.16.0.1',
        'wss://172.31.255.255',
        'wss://192.168.1.10',
        'wss://169.254.169.254',
        'wss://100.64.0.1',
        'wss://239.0.0.1',
        'wss://[::1]',
        'wss://[fd00::1]',
        'wss://[fe80::1]',
        'wss://[::ffff:127.0.0.1]',
        'wss://nas.local',
        'wss://metadata.internal',
        'wss://router',
      ]) {
        expect(policy.rejectionReason(url), isNotNull, reason: url);
      }
    });

    test('accepts public addresses next to the private ranges', () {
      for (final url in [
        'wss://172.15.0.1',
        'wss://172.32.0.1',
        'wss://11.0.0.1',
        'wss://[2001:db8::1]',
      ]) {
        expect(policy.rejectionReason(url), isNull, reason: url);
      }
    });
  });

  group('RelayUrlPolicy.permissive', () {
    const policy = RelayUrlPolicy.permissive;

    test('accepts ws and private hosts', () {
      for (final url in ['ws://localhost:4869', 'ws://127.0.0.1:59999']) {
        expect(policy.rejectionReason(url), isNull, reason: url);
      }
    });

    test('still rejects a non-relay scheme', () {
      expect(policy.rejectionReason('http://relay.example.com'), isNotNull);
    });
  });

  test('rejects a payload targeting a private relay', () async {
    await expectLater(
      ScheduleRequestPayload.parseAndValidate(
        _payload(['wss://relay.example.com', 'ws://127.0.0.1:4869']),
        eventVerifier: Bip340EventVerifier(useIsolate: false),
        relayPolicy: RelayUrlPolicy.public,
      ),
      throwsA(
        isA<PayloadValidationException>().having(
          (error) => error.jobId,
          'jobId',
          'a' * 64,
        ),
      ),
    );
  });
}

String _payload(List<String> relays) {
  return '''
{
  "job_id": "${'a' * 64}",
  "schedule_at": 2000000000,
  "relays": ${relays.map((relay) => '"$relay"').toList()},
  "signed_event": {}
}
''';
}
