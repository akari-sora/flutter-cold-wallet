import 'package:flutter/material.dart';

import 'components.dart';
import 'privacy_policy.dart';
import 'tokens.dart';

/// Required wherever the apps describe themselves (ADR-005 §10.3).
const fcwUnauditedNotice = '未經第三方安全稽核，請先小額使用';
const fcwUnauditedNoticeEn =
    'Not audited by a third party. Start with small amounts.';

const fcwSourceUrl = 'https://gitlab.com/aa22396584/mobile_cold_wallet';
const fcwLicenseNotice =
    '存取：此 GitLab repository 目前需要驗證，尚未開放匿名存取。\n'
    '授權：AGPL-3.0-or-later，並附加允許使用 Google ML Kit 與 Google Play 服務的額外許可。發行者仍須依 AGPL 提供對應原始碼。';

/// The unaudited notice as both apps show it on their main screens.
class FcwUnauditedBanner extends StatelessWidget {
  const FcwUnauditedBanner({super.key});

  @override
  Widget build(BuildContext context) => const FcwBanner(
        tone: FcwTone.warning,
        icon: Icons.gpp_maybe_outlined,
        message: fcwUnauditedNotice,
      );
}

/// Name, version, the unaudited notice, the source and the whole privacy
/// policy. It takes no app state, so the Vault can open it while locked.
class FcwAboutPage extends StatelessWidget {
  final String appName;

  /// `name+build`, as in pubspec.yaml.
  final String version;

  /// App-specific guidance shown under the unaudited notice.
  final List<Widget> notes;

  const FcwAboutPage({
    super.key,
    required this.appName,
    required this.version,
    this.notes = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final parts = version.split('+');
    return Scaffold(
      appBar: AppBar(title: const Text('關於')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              FcwSpace.page, FcwSpace.sm, FcwSpace.page, FcwSpace.xxl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(appName, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: FcwSpace.xs),
                  Text(
                      parts.length == 2
                          ? '版本 ${parts[0]}（建置 ${parts[1]}）'
                          : '版本 $version',
                      key: const Key('about_version_text'),
                      style: theme.textTheme.bodyLarge?.copyWith(color: muted)),
                  const SizedBox(height: FcwSpace.lg),
                  const FcwBanner(
                    tone: FcwTone.warning,
                    icon: Icons.gpp_maybe_outlined,
                    title: fcwUnauditedNotice,
                    message: fcwUnauditedNoticeEn,
                  ),
                  for (final note in notes) ...[
                    const SizedBox(height: FcwSpace.md),
                    note,
                  ],
                  const SizedBox(height: FcwSpace.lg),
                  FcwPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('原始碼',
                            style: theme.textTheme.labelMedium
                                ?.copyWith(color: muted)),
                        const SizedBox(height: 6),
                        SelectableText(fcwSourceUrl,
                            key: const Key('about_source_url'),
                            style: fcwMono(theme.textTheme.bodyLarge)),
                        const SizedBox(height: FcwSpace.md),
                        const Text(fcwLicenseNotice),
                      ],
                    ),
                  ),
                  const SizedBox(height: FcwSpace.xl),
                  const FcwPolicyText(fcwPrivacyPolicyZhTw,
                      key: Key('about_privacy_policy_zh')),
                  const SizedBox(height: FcwSpace.xl),
                  FcwPanel(
                    padding:
                        const EdgeInsets.symmetric(horizontal: FcwSpace.md),
                    child: ExpansionTile(
                      key: const Key('about_privacy_policy_en_toggle'),
                      leading: const Icon(Icons.translate),
                      title: const Text('Privacy policy in English'),
                      childrenPadding:
                          const EdgeInsets.only(bottom: FcwSpace.lg),
                      children: const [
                        FcwPolicyText(fcwPrivacyPolicyEn,
                            key: Key('about_privacy_policy_en')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders the Markdown subset the policy uses: `#` headings, `- ` bullets,
/// paragraphs, **bold**, `code` and <links>. No package: the Vault is offline.
class FcwPolicyText extends StatelessWidget {
  final String markdown;

  const FcwPolicyText(this.markdown, {super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final blocks = <Widget>[];
    final paragraph = <String>[];
    void add(Widget block, {double above = FcwSpace.md}) {
      if (blocks.isNotEmpty) blocks.add(SizedBox(height: above));
      blocks.add(block);
    }

    void endParagraph() {
      if (paragraph.isEmpty) return;
      add(_rich(paragraph.join(' '), text.bodyMedium));
      paragraph.clear();
    }

    for (final line in markdown.split('\n').map((line) => line.trim())) {
      final heading = RegExp(r'^(#{1,3}) (.+)$').firstMatch(line);
      if (line.isEmpty) {
        endParagraph();
      } else if (heading != null) {
        endParagraph();
        final level = heading.group(1)!.length;
        add(
            Semantics(
              header: true,
              child: _rich(
                  heading.group(2)!,
                  switch (level) {
                    1 => text.headlineSmall,
                    2 => text.titleMedium,
                    _ => text.titleSmall,
                  }),
            ),
            above: level == 3 ? FcwSpace.lg : FcwSpace.xl);
      } else if (line.startsWith('- ')) {
        endParagraph();
        add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: text.bodyMedium),
                Expanded(child: _rich(line.substring(2), text.bodyMedium)),
              ],
            ),
            above: FcwSpace.sm);
      } else {
        paragraph.add(line);
      }
    }
    endParagraph();
    return SelectionArea(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: blocks),
    );
  }

  static Widget _rich(String source, TextStyle? style) {
    final spans = <InlineSpan>[];
    var start = 0;
    for (final match in RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|<(https?://[^>]+)>')
        .allMatches(source)) {
      if (match.start > start) {
        spans.add(TextSpan(text: source.substring(start, match.start)));
      }
      spans.add(match.group(1) != null
          ? TextSpan(
              text: match.group(1),
              style: const TextStyle(fontWeight: FontWeight.w700))
          : match.group(2) != null
              ? TextSpan(
                  text: match.group(2),
                  style: fcwMono(style).copyWith(height: style?.height))
              : TextSpan(text: match.group(3)));
      start = match.end;
    }
    if (start < source.length)
      spans.add(TextSpan(text: source.substring(start)));
    return Text.rich(TextSpan(children: spans), style: style);
  }
}
