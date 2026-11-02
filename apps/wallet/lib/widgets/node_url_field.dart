import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../services/node_url_policy.dart';

/// Shown under every node URL field: what the operator of that node learns.
const nodeDataDisclosure = '這個節點會收到你的地址、交易與 IP 位址。請使用你信任的節點。';

/// Bitcoin Core also gets the descriptors and the RPC credentials.
const bitcoinNodeDataDisclosure =
    '這個節點會收到你的地址、交易、IP 位址、含擴充公鑰的帳戶描述（descriptor），以及你填的 RPC 使用者名稱與密碼。請使用你信任的節點。';

/// Node URL input that says what the node receives and shows, while typing,
/// what the URL policy will do: refuse plaintext to a public host, note that
/// plaintext to this phone stays on it, or warn that a network can read it.
class NodeUrlField extends StatelessWidget {
  final TextEditingController controller;
  final Key? fieldKey;
  final bool enabled;

  /// A Bitcoin Core node, which also receives descriptors and credentials.
  final bool bitcoin;

  const NodeUrlField(
      {super.key,
      required this.controller,
      this.fieldKey,
      this.enabled = true,
      this.bitcoin = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final kind = NodeUrlPolicy.classify(value.text.trim());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: fieldKey,
              controller: controller,
              enabled: enabled,
              decoration: InputDecoration(
                labelText: 'RPC 網址',
                errorText: kind == NodeUrlKind.publicHttp
                    ? NodeUrlPolicy.publicHttpRefused
                    : null,
                errorMaxLines: 3,
              ),
            ),
            const SizedBox(height: FcwSpace.sm),
            Text(bitcoin ? bitcoinNodeDataDisclosure : nodeDataDisclosure,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            if (kind == NodeUrlKind.loopbackHttp) ...[
              const SizedBox(height: FcwSpace.sm),
              const FcwBanner(
                key: Key('node_url_loopback_note'),
                tone: FcwTone.info,
                icon: Icons.phone_android_outlined,
                message: NodeUrlPolicy.loopbackNote,
              ),
            ],
            if (kind == NodeUrlKind.privateHttp) ...[
              const SizedBox(height: FcwSpace.sm),
              FcwBanner(
                key: const Key('node_url_plaintext_warning'),
                tone: FcwTone.warning,
                icon: Icons.lock_open_outlined,
                message: bitcoin
                    ? NodeUrlPolicy.plaintextWarningWithCredentials
                    : NodeUrlPolicy.plaintextWarning,
              ),
            ],
          ],
        );
      },
    );
  }
}
