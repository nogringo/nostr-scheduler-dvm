// ignore_for_file: prefer_initializing_formals, use_null_aware_elements

import 'dart:convert';

import 'package:ndk/ndk.dart';

import 'scheduler_dvm_config.dart';

/// Signs and broadcasts the DVM's feedback and its NIP-89 announcement.
class FeedbackPublisher {
  static const int feedbackKind = 7000;
  static const int discoveryKind = 31990;
  static const String legacyEphemeralPubkeyTag = 'ephemeral-pubkey';

  final SchedulerDvmConfig _config;
  SchedulerDvmRelays _relays;
  SchedulerDvmProfile _profile;

  FeedbackPublisher(this._config, this._profile, this._relays);

  void updateRelays(SchedulerDvmRelays relays) {
    _relays = relays;
  }

  void updateProfile(SchedulerDvmProfile profile) {
    _profile = profile;
  }

  /// Relay failures and timeouts are ignored, so it only throws when
  /// encryption or signing fails.
  Future<Nip01Event> publishFeedback({
    required String jobId,
    required String clientPubkey,
    required String status,
    String? message,
  }) async {
    final payload = jsonEncode({
      'status': status,
      if (message != null) 'message': message,
    });
    final encrypted = await _config.signer.encryptNip44(
      plaintext: payload,
      recipientPubKey: clientPubkey,
    );
    if (encrypted == null) {
      throw StateError('Failed to encrypt feedback');
    }

    final event = Nip01Event(
      pubKey: _config.dvmPubkey,
      kind: feedbackKind,
      tags: [
        ['r', jobId],
        // Clients written against the earlier spec read the sender key from
        // this tag instead of from the event pubkey.
        if (_config.legacyEphemeralPubkeyTag)
          [legacyEphemeralPubkeyTag, _config.dvmPubkey],
      ],
      content: encrypted,
      createdAt: _nowSeconds(),
    );
    final signed = await _config.signer.sign(event);
    await _broadcast(signed);
    return signed;
  }

  Future<Nip01Event> publishDiscovery() async {
    final event = Nip01Event(
      pubKey: _config.dvmPubkey,
      kind: discoveryKind,
      tags: [
        ['k', '5905'],
        ['t', 'scheduler'],
      ],
      content: jsonEncode({'name': _profile.name, 'about': _profile.about}),
      createdAt: _nowSeconds(),
    );
    final signed = await _config.signer.sign(event);
    await _broadcast(signed);
    return signed;
  }

  Future<void> _broadcast(Nip01Event event) async {
    const timeout = Duration(seconds: 8);
    final response = _config.ndk.broadcast.broadcast(
      nostrEvent: event,
      specificRelays: _relays.feedbackRelays,
      customSigner: _config.signer,
      timeout: timeout,
    );
    try {
      await response.broadcastDoneFuture.timeout(timeout);
    } catch (_) {
      // Feedback should not crash the DVM if every relay is temporarily down.
    }
  }

  int _nowSeconds() => _config.clock().millisecondsSinceEpoch ~/ 1000;
}
