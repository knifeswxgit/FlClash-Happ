import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/features/happ/subscription.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

typedef HappHeaders = ({String hwid, String userAgent});

String? happHeadersIssue(AppLocalizations l10n, String hwid, String userAgent) {
  if (!validHappHwid(hwid.trim())) return l10n.happInvalidHwid;
  if (!validHappUserAgent(userAgent.trim())) return l10n.happInvalidUserAgent;
  return null;
}

class HappHeaderFields extends StatelessWidget {
  const HappHeaderFields({
    super.key,
    required this.hwid,
    required this.userAgent,
    this.showValidation = false,
    this.onChanged,
  });

  final TextEditingController hwid;
  final TextEditingController userAgent;
  final bool showValidation;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return generateSection(
      items: [
        FormRow(
          title: 'HWID',
          invalid: showValidation && !validHappHwid(hwid.text.trim()),
          trailing: FormRowSecretTextField(
            controller: hwid,
            hintText: l10n.auto,
            onChanged: onChanged,
          ),
        ),
        FormRow(
          title: l10n.userAgent,
          invalid: showValidation && !validHappUserAgent(userAgent.text.trim()),
          trailing: FormRowTextField(
            controller: userAgent,
            hintText: defaultHappUserAgent,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

Future<HappHeaders?> showHappHeadersForm(BuildContext context, String hwid) {
  return showFormSheet<HappHeaders>(
    context: context,
    builder: (_) => _HappHeadersForm(hwid: hwid),
  );
}

class _HappHeadersForm extends StatefulWidget {
  const _HappHeadersForm({required this.hwid});

  final String hwid;

  @override
  State<_HappHeadersForm> createState() => _HappHeadersFormState();
}

class _HappHeadersFormState extends State<_HappHeadersForm> {
  late final TextEditingController _hwid;
  final _userAgent = TextEditingController();
  bool _attempted = false;

  @override
  void initState() {
    super.initState();
    _hwid = TextEditingController(text: widget.hwid);
  }

  @override
  void dispose() {
    _hwid.dispose();
    _userAgent.dispose();
    super.dispose();
  }

  void _save() {
    if (happHeadersIssue(
          context.appLocalizations,
          _hwid.text,
          _userAgent.text,
        ) !=
        null) {
      setState(() => _attempted = true);
      return;
    }
    Navigator.of(context).pop<HappHeaders>((
      hwid: _hwid.text.trim(),
      userAgent: _userAgent.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return FormPage(
      title: 'Happ / Xray',
      saveLabel: l10n.submit,
      onSave: _save,
      error: _attempted
          ? happHeadersIssue(l10n, _hwid.text, _userAgent.text)
          : null,
      children: [
        HappHeaderFields(
          hwid: _hwid,
          userAgent: _userAgent,
          showValidation: _attempted,
          onChanged: (_) {
            if (_attempted) setState(() {});
          },
        ),
      ],
    );
  }
}
