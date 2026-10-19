# ログイン機能の接続手順

メール・パスワード認証はSupabase Authに接続する実装です。認証プロジェクトはまだ接続されていません。設定なしのビルドはゲストで起動し、アカウント画面に接続設定が必要と表示します。

## Supabase側

1. 自分のSupabaseアカウントでプロジェクトを用意します。
2. AuthenticationのEmail認証とメール確認を有効にします。パスワードの最低文字数は8文字以上にします。
3. Authentication → URL Configuration → Redirect URLsに `jp.atode.atode://auth-callback/` を追加します。確認メール・再設定メールはこのURLでアプリに戻ります。
4. Project URLと、公開用のpublishable key（または従来のanon key）を取得します。service_role・sb_secretキーはアプリに設定しないでください。

保存アイテムは引き続き端末内のSQLiteです。この段階ではSupabaseに保存アイテム用のテーブルは作らず、クラウド同期も行いません。

## アプリ側

`config/auth.example.json`を`config/auth.json`にコピーして値を入力します。このローカル設定ファイルはGitの管理対象から除外しています。公開キーはアプリに含まれる前提の値です。

```json
{
  "SUPABASE_URL": "https://your-project.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_..."
}
```

```powershell
flutter run -d emulator-5554 --dart-define-from-file=config/auth.json
flutter build apk --debug --dart-define-from-file=config/auth.json
```

設定値の変更後はホットリロードではなく、アプリを停止して再起動してください。

## 利用方法

- ヘッダーの人型アイコンからログイン・新規登録・パスワード再設定を開きます。
- 新規登録後、確認メールのリンクをこのアプリを入れた端末で開きます。確認メールが届かない場合は迷惑メールやSupabase側の送信状況を確認します。
- 再設定メールも、送信操作を行った端末で開きます。リンクの確認後、新しいパスワードを入力します。
- ログアウト後はゲストに戻ります。保存は削除しません。
- ログイン後のアカウント画面で「ゲストの保存を引き継ぐ」を選ぶと、件数・対象メールアドレスを確認して追加できます。ゲスト側は残し、同じID・URLはスキップします。

## データとセッション

- 以前からの`atode.db`はゲスト用としてそのまま使います。
- ログイン後は認証プロジェクトとユーザーIDの組み合わせから生成した別のDBを使い、アカウント間で一覧・履歴・バックアップを分けます。
- 認証セッションは`flutter_secure_storage`で保存します。パスワードはSQLiteやバックアップに保存しません。
- メール確認が必要な登録では、メール送信レスポンスだけでログイン済みにはしません。
- エラー表示では認証レスポンスやトークンの生データを表示しません。
- AndroidはAPI 24以上、iOSは14.0以上が対象です。AndroidのOS自動バックアップは無効にし、保存内容の引き継ぎにはアプリのバックアップを使います。

## 実サービスでの確認項目

認証サービス接続後に、新規登録→メール確認→ログイン→アプリ再起動でのセッション維持→ログアウトを確認してください。別アカウントで一覧が分かれること、ゲストデータの明示的な引き継ぎ、再設定メール→パスワード更新→新パスワードでのログインも確認します。

認証APIの呼び出しはHTTPモック、登録・入力検証・パスワード再設定・アカウント切り替え・ゲスト引き継ぎは偽の認証サービスで自動テストしています。実メール送信と実サービスへの認証は未検証です。

参考: [Supabase Flutter認証](https://supabase.com/docs/reference/dart/auth-signinwithpassword)、[モバイルへのリダイレクト](https://supabase.com/docs/guides/auth/native-mobile-deep-linking?platform=flutter)。
