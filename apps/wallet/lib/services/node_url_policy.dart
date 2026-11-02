/// How a node URL may be used.
enum NodeUrlKind {
  /// Not an http(s) URL with a host, or it carries a user name or password.
  invalid,
  https,

  /// Plaintext that stays on this phone (loopback).
  loopbackHttp,

  /// Plaintext to a private network or a local name: others on that network
  /// can read it.
  privateHttp,

  /// Plaintext to anything else; refused.
  publicHttp,
}

/// The one rule for every URL that reaches a node. Plaintext carries the
/// addresses, transactions and Bitcoin Core credentials, so it is allowed only
/// where the path stays on this phone or a home network.
class NodeUrlPolicy {
  static const publicHttpRefused = '公開網路上的節點請使用 https://';
  static const loopbackNote = '此連線未加密，但只在這支手機內傳送，不會經過網路。';
  static const plaintextWarning = '此連線未加密：同一網路上的其他裝置可以看到你的地址與交易。只在你信任的家用網路使用。';

  /// Bitcoin Core also receives the descriptors, which carry the extended
  /// public key, and the RPC user name and password.
  static const plaintextWarningWithCredentials =
      '此連線未加密：同一網路上的其他裝置可以看到你的地址、交易、含擴充公鑰的帳戶描述與節點帳號密碼。只在你信任的家用網路使用。';

  /// Shown instead of contacting a node whose URL was saved before this rule
  /// and is now refused, so the user learns nothing was sent; null if allowed.
  static String? savedUrlRefusal(String url,
          {required String settings, String outcome = '未傳送交易'}) =>
      classify(url) == NodeUrlKind.publicHttp
          ? '已不再允許使用此節點網址：$publicHttpRefused。本次$outcome，請到$settings修改網址。'
          : null;

  static NodeUrlKind classify(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return NodeUrlKind.invalid;
    }
    if (uri.scheme == 'https') return NodeUrlKind.https;
    return plaintextKind(uri.host);
  }

  /// Where plaintext to [host] would travel: [NodeUrlKind.loopbackHttp],
  /// [NodeUrlKind.privateHttp] or, refused, [NodeUrlKind.publicHttp].
  /// [host] as `Uri.host` gives it: lower case, IPv6 without brackets.
  static NodeUrlKind plaintextKind(String host) {
    host = host.toLowerCase();
    if (host == 'localhost') return NodeUrlKind.loopbackHttp;
    if (host.contains(':')) {
      // `Uri.host` keeps a zone index as `%25<zone>`.
      final List<int> bytes;
      try {
        bytes = Uri.parseIPv6Address(host.split('%').first);
      } on FormatException {
        return NodeUrlKind.publicHttp;
      }
      return _ipv6Kind(bytes);
    }
    // Strict dotted quad only: the resolver also reads forms such as
    // `127.1`, `0x7f000001` or `010.0.0.1`, and reads them differently.
    if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
      try {
        return _ipv4Kind(Uri.parseIPv4Address(host));
      } on FormatException {
        return NodeUrlKind.publicHttp;
      }
    }
    final labels = host.split('.');
    if (labels.any((label) =>
        !RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$').hasMatch(label))) {
      // Empty labels (a trailing dot) and percent-encoded names.
      return NodeUrlKind.publicHttp;
    }
    final local = labels.length > 1
        ? labels.last == 'local'
        // A lone number is an IPv4 address to the resolver, not a name.
        : !RegExp(r'^(0x[0-9a-f]*|[0-9]+)$').hasMatch(host);
    return local ? NodeUrlKind.privateHttp : NodeUrlKind.publicHttp;
  }

  static NodeUrlKind _ipv4Kind(List<int> b) {
    if (b[0] == 127) return NodeUrlKind.loopbackHttp;
    return b[0] == 10 ||
            (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
            (b[0] == 192 && b[1] == 168) ||
            (b[0] == 169 && b[1] == 254)
        ? NodeUrlKind.privateHttp
        : NodeUrlKind.publicHttp;
  }

  static NodeUrlKind _ipv6Kind(List<int> b) {
    final zeroPrefix = b.take(10).every((byte) => byte == 0);
    if (zeroPrefix && b[10] == 0xff && b[11] == 0xff) {
      return _ipv4Kind(b.sublist(12)); // IPv4-mapped
    }
    if (zeroPrefix &&
        b.skip(10).take(5).every((byte) => byte == 0) &&
        b[15] == 1) {
      return NodeUrlKind.loopbackHttp; // ::1
    }
    return (b[0] & 0xfe) == 0xfc || // fc00::/7
            (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) // fe80::/10
        ? NodeUrlKind.privateHttp
        : NodeUrlKind.publicHttp;
  }
}
