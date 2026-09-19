/// Which target relay URLs a schedule request may ask the DVM to publish to.
///
/// The check is lexical: a hostname that resolves to a private address still
/// passes. It keeps a request from aiming the DVM straight at the host it runs
/// on, not from every form of SSRF.
class RelayUrlPolicy {
  /// Public `wss://` relays only. The default for a DVM open to the network.
  static const RelayUrlPolicy public = RelayUrlPolicy();

  /// Any relay URL, including `ws://localhost`. Meant for tests and for a DVM
  /// serving only its own machine.
  static const RelayUrlPolicy permissive = RelayUrlPolicy(
    allowInsecure: true,
    allowPrivate: true,
  );

  /// Whether `ws://` is accepted next to `wss://`.
  final bool allowInsecure;

  /// Whether loopback, private and link-local hosts are accepted.
  final bool allowPrivate;

  const RelayUrlPolicy({this.allowInsecure = false, this.allowPrivate = false});

  /// Why [url] is not an acceptable target relay, or null when it is.
  String? rejectionReason(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return '$url is not a relay URL';
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'wss' && !(allowInsecure && scheme == 'ws')) {
      return allowInsecure
          ? '$url must use ws:// or wss://'
          : '$url must use wss://';
    }

    if (allowPrivate) return null;

    final host = uri.host.toLowerCase();
    if (_isPrivateHost(host)) return '$url must be a public relay';
    return null;
  }

  bool _isPrivateHost(String host) {
    if (host.contains(':')) return _isPrivateIpv6(host);

    final ipv4 = _parseIpv4(host);
    if (ipv4 != null) return _isPrivateIpv4(ipv4);

    if (host == 'localhost' || host.endsWith('.localhost')) return true;
    if (host.endsWith('.local') || host.endsWith('.internal')) return true;
    // A single-label host is an intranet name, never a public relay.
    return !host.contains('.');
  }

  static List<int>? _parseIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      octets.add(octet);
    }
    return octets;
  }

  static bool _isPrivateIpv4(List<int> octets) {
    final [first, second, ...] = octets;
    if (first == 0 || first == 10 || first == 127) return true;
    if (first == 169 && second == 254) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    if (first == 192 && second == 168) return true;
    if (first == 100 && second >= 64 && second <= 127) return true;
    if (first == 198 && (second == 18 || second == 19)) return true;
    return first >= 224;
  }

  static bool _isPrivateIpv6(String host) {
    final address = host.replaceAll('[', '').replaceAll(']', '');
    if (address == '::1' || address == '::') return true;
    // IPv4-mapped addresses carry their IPv4 privacy.
    final mapped = address.split(':').last;
    final ipv4 = _parseIpv4(mapped);
    if (ipv4 != null) return _isPrivateIpv4(ipv4);
    // Unique local (fc00::/7) and link-local (fe80::/10).
    return RegExp(r'^f[cd]').hasMatch(address) ||
        RegExp(r'^fe[89ab]').hasMatch(address);
  }
}
