import 'package:flutter/material.dart';
import 'auth.dart';
import 'data.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.auth,
    required this.guest,
    required this.repository,
  });
  final AccountAuth auth;
  final Repository guest, repository;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController(),
      password = TextEditingController(),
      confirm = TextEditingController();
  String mode = 'ログイン';
  bool busy = false, hidden = true, confirming = false;
  String? message;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = authErrorMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          confirming = false;
        });
      }
    }
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    await run(() async {
      if (mode == '新規登録') {
        final checkEmail = await widget.auth.signUp(email.text, password.text);
        if (mounted) {
          setState(
            () => message = checkEmail
                ? '確認メールを送信しました。リンクを開いて登録を完了してください。届かない場合は迷惑メールフォルダーも確認してください。'
                : '登録しました。',
          );
        }
      } else if (mode == 'パスワード再設定') {
        await widget.auth.sendReset(email.text);
        if (mounted) {
          setState(
            () => message = '登録されている場合、再設定メールが届きます。メールのリンクをこの端末で開いてください。',
          );
        }
      } else {
        await widget.auth.signIn(email.text, password.text);
      }
      if (mounted) {
        password.clear();
        confirm.clear();
      }
    });
  }

  Future<void> importGuest() => run(() async {
    final incoming = await widget.guest.load();
    final existing = await widget.repository.load();
    final plan = planRestore(existing, incoming);
    if (!mounted) return;
    setState(() => confirming = true);
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ゲストの保存を引き継ぐ'),
        content: Text(
          'この端末のゲストデータ${incoming.length}件のうち、${plan.additions.length}件を「${widget.auth.identity?.email}」に追加します。重複${plan.skipped}件はスキップします。\n\nゲストのデータは残ります。このアカウントへ追加してよい内容か確認してください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: plan.additions.isEmpty
                ? null
                : () => Navigator.pop(c, true),
            child: const Text('追加する'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => confirming = false);
    if (yes != true) return;
    final repo = widget.repository;
    if (repo is! RestorableRepository) {
      throw const LoginFailure('引き継ぎに対応していません。');
    }
    final result = await repo.restoreMissing(incoming);
    if (mounted) {
      setState(() => message = '${result.additions.length}件を引き継ぎました。');
    }
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (_, _) => buildAccount(context),
  );
  Widget buildAccount(BuildContext context) {
    final auth = widget.auth, identity = auth.identity;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('アカウント'),
          automaticallyImplyLeading: !busy,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Icon(Icons.account_circle_outlined, size: 56),
                const SizedBox(height: 20),
                if (identity != null) ...[
                  const Text(
                    'ログイン中',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(identity.email),
                  const SizedBox(height: 16),
                  const Text(
                    'この端末の保存をアカウントごとに管理します。クラウド同期はまだありません。機種変更にはバックアップをご利用ください。',
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton(
                    onPressed: busy ? null : importGuest,
                    child: const Text('ゲストの保存を引き継ぐ'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: busy ? null : () => run(widget.auth.signOut),
                    child: const Text('ログアウト'),
                  ),
                ] else ...[
                  Text(
                    mode,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!auth.configured)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(auth.unavailableMessage!),
                      ),
                    ),
                  Form(
                    key: form,
                    child: AutofillGroup(
                      child: Column(
                        children: [
                          TextFormField(
                            controller: email,
                            enabled: !busy,
                            autofillHints: const [AutofillHints.email],
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'メールアドレス',
                            ),
                            validator: validateEmail,
                          ),
                          const SizedBox(height: 16),
                          if (mode != 'パスワード再設定') ...[
                            TextFormField(
                              controller: password,
                              enabled: !busy,
                              obscureText: hidden,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: [
                                mode == '新規登録'
                                    ? AutofillHints.newPassword
                                    : AutofillHints.password,
                              ],
                              decoration: InputDecoration(
                                labelText: 'パスワード',
                                suffixIcon: IconButton(
                                  tooltip: hidden ? 'パスワードを表示' : 'パスワードを隠す',
                                  onPressed: () =>
                                      setState(() => hidden = !hidden),
                                  icon: Icon(
                                    hidden
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: (s) => mode == '新規登録'
                                  ? validateNewPassword(s)
                                  : (s?.isEmpty ?? true)
                                  ? 'パスワードを入力してください'
                                  : null,
                            ),
                            const SizedBox(height: 16),
                          ],
                          if (mode == '新規登録') ...[
                            TextFormField(
                              controller: confirm,
                              enabled: !busy,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: 'パスワード（確認）',
                              ),
                              validator: (s) =>
                                  s == password.text ? null : 'パスワードが一致しません',
                            ),
                            const SizedBox(height: 16),
                          ],
                          FilledButton(
                            onPressed: busy || !auth.configured ? null : submit,
                            child: Text(
                              mode == 'パスワード再設定' ? '再設定メールを送信' : mode,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: ['ログイン', '新規登録', 'パスワード再設定']
                        .where((s) => s != mode)
                        .map(
                          (s) => TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                    mode = s;
                                    message = null;
                                    password.clear();
                                    confirm.clear();
                                    form.currentState?.reset();
                                  }),
                            child: Text(s),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  const Text('ログインしなくても保存・検索・バックアップを利用できます。'),
                ],
                if (busy && !confirming)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  ),
                if (message != null || auth.eventError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      message ?? auth.eventError!,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PasswordUpdateScreen extends StatefulWidget {
  const PasswordUpdateScreen({super.key, required this.auth});
  final AccountAuth auth;
  @override
  State<PasswordUpdateScreen> createState() => _PasswordUpdateScreenState();
}

class _PasswordUpdateScreenState extends State<PasswordUpdateScreen> {
  final form = GlobalKey<FormState>();
  final password = TextEditingController(), confirm = TextEditingController();
  bool busy = false;
  String? message;
  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> apply() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.auth.changePassword(password.text);
    } catch (e) {
      if (mounted) setState(() => message = authErrorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('新しいパスワード')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('メールの確認ができました。新しいパスワードを設定してください。'),
              const SizedBox(height: 24),
              TextFormField(
                controller: password,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.newPassword],
                decoration: const InputDecoration(labelText: '新しいパスワード'),
                validator: validateNewPassword,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: confirm,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'パスワード（確認）'),
                validator: (s) => s == password.text ? null : 'パスワードが一致しません',
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy ? null : apply,
                child: Text(busy ? '更新中…' : 'パスワードを更新'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await widget.auth.signOut();
                        } catch (e) {
                          if (mounted) {
                            setState(() => message = authErrorMessage(e));
                          }
                        }
                      },
                child: const Text('キャンセルしてログアウト'),
              ),
              if (message != null) Text(message!),
            ],
          ),
        ),
      ),
    ),
  );
}
