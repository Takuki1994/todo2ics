use strict;
use warnings;
use utf8;

use Cwd qw(getcwd);
use Encode qw(decode encode);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3;
use MIME::Base64 qw(decode_base64 encode_base64);
use Test::More;
use Symbol qw(gensym);

my $script = File::Spec->rel2abs('todo2ics.pl');
my $temp_dir = tempdir(CLEANUP => 1);
my $input_path = File::Spec->catfile($temp_dir, 'todo.txt');
my $newline = "\r\n";
my $todo = join $newline,
    '(A) 2026-11-09 Draft +work @calendar t:2026-11-10 due:2026-11-15 cat:work cat:projectA',
    '2024-02-28 Review, follow-up due:2024-02-29 @calendar cat:family',
    '2026-03-01 通院 due:2026-03-01 @calendar',
    'Bad date due:2026-02-30 @calendar',
    'Bad start t:nope due:2026-12-01 @calendar',
    'Later t:2026-12-02 due:2026-12-01 @calendar',
    'Missing due @calendar',
    'Plain task @scheduled',
    '';
write_utf8($input_path, $todo);

my ($status, $stdout, $stderr) = run_script($script, $input_path);
is($status, 0, 'normal conversion succeeds');
is(
    $stdout,
    join($newline,
        (
            '(A) 2026-11-09 Draft +work @scheduled t:2026-11-10 due:2026-11-15 cat:work cat:projectA',
            '2024-02-28 Review, follow-up due:2024-02-29 @scheduled cat:family',
            '2026-03-01 通院 due:2026-03-01 @scheduled',
            'Bad date due:2026-02-30 @calendar',
            'Bad start t:nope due:2026-12-01 @calendar',
            'Later t:2026-12-02 due:2026-12-01 @calendar',
            'Missing due @calendar',
            'Plain task @scheduled',
            '',
        )
    ),
    'stdout contains the full todo text with successful tasks scheduled',
);
like($stderr, qr/Generated: 3 events/, 'reports event count');
like($stderr, qr/Warnings: 4/, 'reports invalid tasks');
like($stderr, qr/line 4: invalid due:/, 'warns about invalid due date');
like($stderr, qr/line 5: invalid t:/, 'warns about invalid start date');

my $ics_path = File::Spec->catfile($temp_dir, 'ics', 'todo.ics');
ok(-f $ics_path, 'writes ICS beside the input in the ics directory');
my $ics = read_utf8($ics_path);
like($ics, qr/BEGIN:VCALENDAR\r\nVERSION:2\.0/, 'writes a VCALENDAR document');
is(() = $ics =~ /BEGIN:VEVENT/g, 3, 'emits only valid tasks as events');
like($ics, qr/DTSTART;VALUE=DATE:20261110\r\nDTEND;VALUE=DATE:20261116/, 'uses t: and exclusive next-day DTEND');
like($ics, qr/DTSTART;VALUE=DATE:20240229\r\nDTEND;VALUE=DATE:20240301/, 'handles leap day and defaults t: to due:');
like($ics, qr/SUMMARY:Draft\r\n/, 'removes priority and project tags from summary');
like($ics, qr/SUMMARY:Review\\, follow-up\r\n/, 'escapes commas in summary');
like($ics, qr/CATEGORIES:work,projectA\r\n/, 'writes multiple categories');
like($ics, qr/CATEGORIES:family\r\n/, 'writes a single category');
like($ics, qr/SUMMARY:通院\r\n/, 'writes UTF-8 task text');
my @event_blocks = $ics =~ /BEGIN:VEVENT\r\n(.*?)END:VEVENT/gs;
unlike($event_blocks[2], qr/CATEGORIES:/, 'omits categories without a cat: tag');
unlike($ics, qr/(?:Bad date|Bad start|Later|Missing due)/, 'omits invalid tasks');
like($ics, qr/UID:[^\r\n]+\r\nDTSTAMP:\d{8}T\d{6}Z/, 'includes event identity and timestamp');
is(read_utf8($input_path), $todo, 'does not modify the source file');

my $dry_dir = File::Spec->catdir($temp_dir, 'dry');
mkdir $dry_dir or die "Cannot create '$dry_dir': $!";
my $dry_path = File::Spec->catfile($dry_dir, 'dry.txt');
write_utf8($dry_path, $todo);
my ($dry_status, $dry_stdout, $dry_stderr);
my ($test_set_codepage, $test_original_codepage);
if ($^O eq 'MSWin32') {
    require Win32::API;
    my $get_codepage = Win32::API->new('kernel32', 'GetConsoleOutputCP', '', 'I')
        or die "Cannot load GetConsoleOutputCP: $^E";
    my $set_codepage = Win32::API->new('kernel32', 'SetConsoleOutputCP', 'I', 'I')
        or die "Cannot load SetConsoleOutputCP: $^E";
    $test_set_codepage = $set_codepage;
    $test_original_codepage = $get_codepage->Call()
        or die "Cannot determine console output code page";
    $set_codepage->Call(932) or die "Cannot set test console output code page";
    my $run_ok = eval {
        ($dry_status, $dry_stdout, $dry_stderr) = run_script($script, '--dry', $dry_path);
        1;
    };
    my $run_error = $@;
    die $run_error unless $run_ok;
}
else {
    ($dry_status, $dry_stdout, $dry_stderr) = run_script($script, '--dry', $dry_path);
}
is($dry_status, 0, 'dry-run succeeds');
is(
    $dry_stdout,
    join($newline,
        (
            '(A) 2026-11-09 Draft +work @calendar t:2026-11-10 due:2026-11-15 cat:work cat:projectA',
            '2024-02-28 Review, follow-up due:2024-02-29 @calendar cat:family',
            '2026-03-01 通院 due:2026-03-01 @calendar',
            'x Bad date due:2026-02-30 @calendar',
            'x Bad start t:nope due:2026-12-01 @calendar',
            'x Later t:2026-12-02 due:2026-12-01 @calendar',
            'x Missing due @calendar',
            '',
        )
    ),
    'dry-run outputs only calendar tasks and marks invalid ones',
);
like($dry_stderr, qr/Warnings: 4/, 'dry-run reports invalid tasks');
ok(!-e File::Spec->catdir($dry_dir, 'ics'), 'dry-run does not create ICS output');
$test_set_codepage->Call($test_original_codepage)
    or die "Cannot restore console output code page"
    if $test_set_codepage;

my $unicode_dir = File::Spec->catdir($temp_dir, '日本語-🌟');
create_unicode_directory($unicode_dir);
my $unicode_path = File::Spec->catfile($unicode_dir, 'todo.txt');
write_unicode_file($unicode_path, "日本語の予定 \@calendar due:2026-11-12\n");
my ($unicode_status, $unicode_stdout, $unicode_stderr) = run_script($script, $unicode_path);
diag $unicode_stderr if $unicode_status != 0;
is($unicode_status, 0, 'accepts a Unicode command-line path');
is(
    $unicode_stdout,
    "日本語の予定 \@scheduled due:2026-11-12\n",
    'converts the todo at the Unicode path',
);
my $unicode_ics_dir = File::Spec->catdir($unicode_dir, 'ics');
my $unicode_ics_path = File::Spec->catfile($unicode_ics_dir, 'todo.ics');
my $unicode_ics = read_unicode_file($unicode_ics_path);
ok(length($unicode_ics), 'writes the ICS file under the Unicode path');
like($unicode_ics, qr/SUMMARY:日本語の予定\r\n/, 'writes Unicode task content');
like($unicode_stderr, qr/Generated: 1 events/, 'reports Unicode-path conversion');

delete_unicode_file($unicode_ics_path);
my ($relative_cwd_status, $relative_cwd_stdout) =
    run_script_in_directory($unicode_dir, $script, 'todo.txt');
is($relative_cwd_status, 0, 'opens a relative filename from a Unicode working directory');
is(
    $relative_cwd_stdout,
    "日本語の予定 \@scheduled due:2026-11-12\n",
    'converts the todo from a Unicode working directory',
);
my $relative_cwd_ics = read_unicode_file($unicode_ics_path);
like($relative_cwd_ics, qr/SUMMARY:日本語の予定\r\n/, 'writes ICS beside a relative input in a Unicode working directory');

delete_unicode_file($unicode_ics_path);
my $relative_unicode_path = File::Spec->catfile('日本語-🌟', 'todo.txt');
my ($relative_unicode_status, $relative_unicode_stdout) =
    run_script_in_directory($temp_dir, $script, $relative_unicode_path);
is($relative_unicode_status, 0, 'accepts a Unicode relative command-line path');
is(
    $relative_unicode_stdout,
    "日本語の予定 \@scheduled due:2026-11-12\n",
    'converts the todo at a Unicode relative path',
);
my $relative_unicode_ics = read_unicode_file($unicode_ics_path);
like($relative_unicode_ics, qr/SUMMARY:日本語の予定\r\n/, 'writes ICS beside a Unicode relative input');

delete_unicode_file($unicode_ics_path);
delete_unicode_file($unicode_path);
remove_unicode_directory($unicode_ics_dir);
remove_unicode_directory($unicode_dir);

my $empty_path = File::Spec->catfile($temp_dir, 'empty.txt');
write_utf8($empty_path, "No calendar tasks\n");
my ($empty_status, $empty_stdout) = run_script($script, $empty_path);
is($empty_status, 0, 'conversion with no calendar tasks succeeds');
is($empty_stdout, "No calendar tasks\n", 'preserves input with no calendar tasks');
ok(-f File::Spec->catfile($temp_dir, 'ics', 'empty.ics'), 'writes an empty calendar');

SKIP: {
    skip 'PowerShell 7 overwrite integration test requires pwsh.exe', 3
        unless has_pwsh();

    my $overwrite_path = File::Spec->catfile($temp_dir, 'overwrite.txt');
    my $overwrite_input = "日本語の予定 \@calendar due:2026-11-12\r\nKeep this line\r\n";
    write_utf8($overwrite_path, $overwrite_input);
    my $powershell = '[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding("utf-8"); '
        . '& { '
        . '$todoPath = ' . powershell_utf8_expression($overwrite_path) . '; '
        . '$perlExe = ' . powershell_utf8_expression($^X) . '; '
        . '$scriptPath = ' . powershell_utf8_expression($script) . '; '
        . '$updatedText = & $perlExe $scriptPath $todoPath; '
        . '$todo2icsExitCode = $LASTEXITCODE; '
        . 'if ($todo2icsExitCode -ne 0) { throw "todo2ics failed: $todo2icsExitCode" }; '
        . 'Set-Content -LiteralPath $todoPath -Value $updatedText -Encoding utf8 '
        . '}; '
        . 'if (Get-Variable todoPath,perlExe,scriptPath,updatedText,todo2icsExitCode -ErrorAction SilentlyContinue) { exit 91 }; '
        . 'exit 0';
    my ($overwrite_status, undef, $overwrite_stderr) = run_pwsh($powershell);
    is($overwrite_status, 0, 'PowerShell safely overwrites the input through Set-Content');
    diag $overwrite_stderr if $overwrite_status != 0;
    is(
        read_utf8($overwrite_path),
        "日本語の予定 \@scheduled due:2026-11-12\r\nKeep this line\r\n",
        'writes the complete UTF-8 converted text back to the input file',
    );
    like(
        read_utf8(File::Spec->catfile($temp_dir, 'ics', 'overwrite.ics')),
        qr/SUMMARY:日本語の予定\r\n/,
        'generates ICS before PowerShell overwrites the todo file',
    );
}

if ($test_set_codepage) {
    my $stderr_path = File::Spec->catfile($temp_dir, 'stderr.txt');
    my $stderr_todo = "Task due:日本語 \@calendar\n";
    write_utf8($stderr_path, $stderr_todo);

    $test_set_codepage->Call(932) or die "Cannot set Japanese test console output code page";
    my ($warning_status, $warning_stdout, $warning_stderr) = run_script($script, $stderr_path);
    is($warning_status, 0, 'conversion succeeds with a Japanese stderr warning');
    is($warning_stdout, $stderr_todo, 'normal stdout remains UTF-8');
    like($warning_stderr, qr/invalid due: date '日本語'/, 'stderr uses the Japanese console code page');

    $test_set_codepage->Call(1252) or die "Cannot set unrepresentable test console output code page";
    my ($unrepresentable_status, undef, $unrepresentable_stderr) =
        run_script($script, '--dry', $dry_path);
    my ($replacement_status, $replacement_stdout, $replacement_stderr) =
        run_script($script, $stderr_path);
    $test_set_codepage->Call($test_original_codepage)
        or die "Cannot restore console output code page";
    is($unrepresentable_status, 1, 'fails explicitly when task text is not representable in the console code page');
    like($unrepresentable_stderr, qr/Cannot encode --dry output using code page 1252/, 'reports output code page errors');
    is($replacement_status, 0, 'conversion succeeds with an unrepresentable stderr message');
    is($replacement_stdout, $stderr_todo, 'normal stdout remains UTF-8 when stderr uses substitutions');
    like($replacement_stderr, qr/invalid due: date '\?\?\?'/, 'replaces stderr characters unsupported by the code page');
}

done_testing();

sub write_utf8 {
    my ($path, $text) = @_;
    open my $file, '>:raw', $path or die "Cannot open '$path': $!";
    print {$file} encode('UTF-8', $text) or die "Cannot write '$path': $!";
    close $file or die "Cannot close '$path': $!";
}

sub read_utf8 {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "Cannot open '$path': $!";
    my $bytes = do { local $/; <$file> };
    close $file or die "Cannot close '$path': $!";
    return decode('UTF-8', $bytes);
}

sub write_unicode_file {
    my ($path, $contents) = @_;
    if ($^O ne 'MSWin32') {
        write_utf8($path, $contents);
        return;
    }

    my $handle = create_test_file_handle($path, 0x40000000, 2);
    my $write_file = Win32::API->new('kernel32', 'WriteFile', 'NPIPP', 'I')
        or die "Cannot load WriteFile: $^E";
    my $bytes = Encode::encode('UTF-8', $contents);
    my $offset = 0;
    while ($offset < length $bytes) {
        my $chunk = substr($bytes, $offset, 65536);
        my $buffer = $chunk . ("\0" x 8);
        my $written = pack('L', 0) . ("\0" x 4);
        $write_file->Call($handle, $buffer, length($chunk), $written, 0)
            or die "Cannot write Unicode test input (Windows error " . Win32::GetLastError() . ")";
        $offset += unpack 'L', $written;
    }
    Win32::API->new('kernel32', 'CloseHandle', 'N', 'I')->Call($handle)
        or die "Cannot close Unicode test input (Windows error " . Win32::GetLastError() . ")";
}

sub read_unicode_file {
    my ($path) = @_;
    return read_utf8($path) if $^O ne 'MSWin32';

    my $handle = create_test_file_handle($path, 0x80000000, 3);
    my $read_file = Win32::API->new('kernel32', 'ReadFile', 'NPIPP', 'I')
        or die "Cannot load ReadFile: $^E";
    my $bytes = '';
    while (1) {
        my $buffer = "\0" x (65536 + 8);
        my $read = pack('L', 0) . ("\0" x 4);
        $read_file->Call($handle, $buffer, 65536, $read, 0)
            or die "Cannot read Unicode test output (Windows error " . Win32::GetLastError() . ")";
        my $count = unpack 'L', $read;
        last unless $count;
        $bytes .= substr($buffer, 0, $count);
    }
    Win32::API->new('kernel32', 'CloseHandle', 'N', 'I')->Call($handle)
        or die "Cannot close Unicode test output (Windows error " . Win32::GetLastError() . ")";
    return decode('UTF-8', $bytes);
}

sub delete_unicode_file {
    my ($path) = @_;
    if ($^O eq 'MSWin32') {
        my $delete_file = Win32::API->new('kernel32', 'DeleteFileW', 'P', 'I')
            or die "Cannot load DeleteFileW: $^E";
        $delete_file->Call(Encode::encode('UTF-16LE', $path . "\0"))
            or die "Cannot delete Unicode test file (Windows error " . Win32::GetLastError() . ")";
        return;
    }
    unlink $path or die "Cannot delete '$path': $!";
}

sub create_unicode_directory {
    my ($path) = @_;
    if ($^O eq 'MSWin32') {
        require Win32::API;
        my $create_directory = Win32::API->new('kernel32', 'CreateDirectoryW', 'PP', 'I')
            or die "Cannot load CreateDirectoryW: $^E";
        $create_directory->Call(Encode::encode('UTF-16LE', $path . "\0"), 0)
            or die "Cannot create Unicode test directory (Windows error " . Win32::GetLastError() . ")";
        return;
    }
    mkdir $path or die "Cannot create '$path': $!";
}

sub remove_unicode_directory {
    my ($path) = @_;
    if ($^O eq 'MSWin32') {
        my $remove_directory = Win32::API->new('kernel32', 'RemoveDirectoryW', 'P', 'I')
            or die "Cannot load RemoveDirectoryW: $^E";
        $remove_directory->Call(Encode::encode('UTF-16LE', $path . "\0"))
            or die "Cannot remove Unicode test directory (Windows error " . Win32::GetLastError() . ")";
        return;
    }
    rmdir $path or die "Cannot remove '$path': $!";
}

sub create_test_file_handle {
    my ($path, $access, $disposition) = @_;
    require Win32::API;
    my $create_file = Win32::API->new('kernel32', 'CreateFileW', 'PIIPIIN', 'N')
        or die "Cannot load CreateFileW: $^E";
    my $handle = $create_file->Call(
        Encode::encode('UTF-16LE', $path . "\0"),
        $access,
        0x7,
        0,
        $disposition,
        0x80,
        0,
    );
    die "Cannot access Unicode test file (Windows error " . Win32::GetLastError() . ")"
        if !defined $handle || $handle == -1;
    return $handle;
}

sub run_script {
    my ($script_path, @arguments) = @_;

    my @command = ($^X, $script_path, @arguments);
    if ($^O eq 'MSWin32' && grep { /[^\x00-\x7F]/ } @command) {
        my $perl_encoded = encode_base64(Encode::encode('UTF-8', $^X), '');
        my $script_encoded = encode_base64(Encode::encode('UTF-8', $script_path), '');
        my $powershell = '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; '
            . '$perl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('
            . "'$perl_encoded')); "
            . '$script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('
            . "'$script_encoded')); "
            . q{& $perl $script};
        for my $argument (@arguments) {
            my $encoded = encode_base64(Encode::encode('UTF-8', $argument), '');
            $powershell .= ' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('
                . "'$encoded')))";
        }
        $powershell .= '; exit $LASTEXITCODE';
        return run_powershell($powershell);
    }

    my $stdout_encoding = $^O eq 'MSWin32' && @arguments && $arguments[0] eq '--dry'
        ? windows_console_encoding()
        : 'UTF-8';
    my $stderr_encoding = windows_console_encoding();
    return run_process($stdout_encoding, $stderr_encoding, @command);
}

sub run_script_in_directory {
    my ($directory, $script_path, @arguments) = @_;
    if ($^O eq 'MSWin32') {
        my $powershell = '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; '
            . '$cwd = ' . powershell_utf8_expression($directory) . '; '
            . 'Set-Location -LiteralPath $cwd; '
            . '$perl = ' . powershell_utf8_expression($^X) . '; '
            . '$script = ' . powershell_utf8_expression($script_path) . '; '
            . q{& $perl $script};
        for my $argument (@arguments) {
            $powershell .= ' (' . powershell_utf8_expression($argument) . ')';
        }
        $powershell .= '; exit $LASTEXITCODE';
        return run_powershell($powershell);
    }

    my $original_directory = getcwd();
    chdir $directory or die "Cannot change to '$directory': $!";

    my @result;
    my $run_ok = eval {
        @result = run_script($script_path, @arguments);
        1;
    };
    my $run_error = $@;
    chdir $original_directory or die "Cannot restore current directory '$original_directory': $!";
    die $run_error unless $run_ok;
    return @result;
}

sub powershell_utf8_expression {
    my ($text) = @_;
    my $encoded = encode_base64(Encode::encode('UTF-8', $text), '');
    return "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded'))";
}

sub run_powershell {
    my ($powershell) = @_;
    my $encoded_command = encode_base64(Encode::encode('UTF-16LE', $powershell), '');
    return run_process(
        'UTF-8',
        'UTF-8',
        'powershell.exe',
        '-NoProfile',
        '-NonInteractive',
        '-OutputFormat',
        'Text',
        '-EncodedCommand',
        $encoded_command,
    );
}

sub run_pwsh {
    my ($powershell) = @_;
    my $encoded_command = encode_base64(Encode::encode('UTF-16LE', $powershell), '');
    return run_process(
        'UTF-8',
        'UTF-8',
        'pwsh.exe',
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        $encoded_command,
    );
}

sub has_pwsh {
    return 0 unless $^O eq 'MSWin32';
    my $path = `where.exe pwsh.exe 2>NUL`;
    return $? == 0 && length $path;
}

sub run_process {
    my ($stdout_encoding, $stderr_encoding, @command) = @_;
    my ($stdout_handle, $stderr_handle);
    my $stdin_handle = gensym();
    $stderr_handle = gensym();
    my $pid = open3(
        $stdin_handle,
        $stdout_handle,
        $stderr_handle,
        @command,
    );
    close $stdin_handle;

    my $stdout_bytes = do { local $/; <$stdout_handle> // '' };
    my $stderr_bytes = do { local $/; <$stderr_handle> // '' };
    close $stdout_handle;
    close $stderr_handle;
    waitpid($pid, 0);
    my $status = $? >> 8;
    return (
        $status,
        decode($stdout_encoding, $stdout_bytes),
        decode($stderr_encoding, $stderr_bytes),
    );
}

sub windows_console_encoding {
    return 'UTF-8' unless $^O eq 'MSWin32';
    require Win32::API;
    my $get_codepage = Win32::API->new('kernel32', 'GetConsoleOutputCP', '', 'I')
        or die "Cannot load GetConsoleOutputCP: $^E";
    my $codepage = $get_codepage->Call()
        or die "Cannot determine console output code page";
    return $codepage == 65001 ? 'UTF-8' : "cp$codepage";
}

