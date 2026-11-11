# todo2ics

todo.txt形式のタスクから、Outlook Web版へインポートするICSファイルを生成するWindows向けPerlスクリプトです。todo.txt自体は変更せず、変換後の全文を標準出力へ出力します。

## 使い方

```cmd
perl todo2ics.pl todo.txt > todo.new.txt
move /Y todo.new.txt todo.txt
```

`todo.txt`と同じフォルダに `ics\todo.ics` を作成します。`@calendar` のある行が対象です。有効なタスクはICSのVEVENTになり、標準出力では `@calendar` が `@scheduled` に置き換わります。エラーや処理状況は標準エラーへ出力します。

事前確認では `--dry` を指定します。ICSを作らず、対象行だけを表示し、日付が不正な行には行頭に `x ` を付けます。Windowsの `--dry` 標準出力と標準エラーは現在のコンソール出力コードページを使います（ファイルへリダイレクトした場合も同じです）。コードページで表現できない標準エラー内の文字は代替文字に置き換えます。通常実行の標準出力と、非Windows環境の標準エラーはUTF-8です。

```cmd
perl todo2ics.pl --dry todo.txt
```

PowerShell 7で日本語を含む標準出力を扱うには、profileに次の設定を追加し、pwshを起動し直してください。Perlからの出力をPowerShellがUTF-8として読み取れるようになります。`$OutputEncoding`はPowerShellからネイティブコマンドへ入力する際の設定なので、この用途では不要です。

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding("utf-8")
```

変換結果を同じ `todo.txt` に書き戻すときは、次のようにスクリプトブロック内で出力を一時変数に受け、終了コードが成功の場合にだけ `Set-Content` を実行します。変数はブロックの外には残りません。入力ファイルへ直接パイプすると、Perlが読み込む前にファイルが切り詰められるため避けてください。

```powershell
& {
    $path = (Resolve-Path .\todo.txt).Path
    $updated = & perl .\todo2ics.pl $path
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "todo2ics failed: $exitCode" }
    Set-Content -LiteralPath $path -Value $updated -Encoding utf8
}
```

対象タスクには `due:YYYY-MM-DD` が必要です。`t:YYYY-MM-DD` があれば開始日、なければdueの日を開始日にします。`cat:<name>` はOutlookカテゴリになります。入力ファイルはUTF-8です。WindowsではUnicodeの引数とファイルパスを扱うためPerlモジュール `Win32::API` が必要です。Perl環境に含まれていない場合は `Win32::API` を追加してください。

## テスト

```cmd
prove -v t
```
