#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Encode qw(decode encode FB_CROAK find_encoding);
use File::Basename qw(basename dirname fileparse);
use File::Path qw(make_path);
use File::Spec;

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

@ARGV = windows_arguments() if $^O eq 'MSWin32';

my $dry_run = 0;
if (@ARGV && $ARGV[0] eq '--dry') {
    $dry_run = 1;
    shift @ARGV;
}

if (@ARGV != 1 || $ARGV[0] =~ /\A--/) {
    fail("Usage: perl todo2ics.pl [--dry] todo.txt", 2);
}

my $input_path = $^O eq 'MSWin32'
    ? File::Spec->rel2abs($ARGV[0], windows_current_directory())
    : File::Spec->rel2abs($ARGV[0]);
my $input_bytes = read_file_bytes($input_path);

my $todo_text = eval { decode('UTF-8', $input_bytes, FB_CROAK) };
if ($@) {
    my $error = $@;
    $error =~ s/\s+\z//;
    fail("Input is not valid UTF-8: $error", 1);
}

my @lines = split /(?<=\n)|(?<=\r)(?!\n)/, $todo_text, -1;
my @events;
my @warnings;
my @dry_output;
my %converted_lines;
my $event_counter = 0;

for my $index (0 .. $#lines) {
    my $line = $lines[$index];
    my ($body, $ending) = split_line_ending($line);
    my @tokens = split /\s+/, $body;
    next unless grep { $_ eq '@calendar' } @tokens;

    my ($event, $reason) = build_event(
        tokens        => \@tokens,
        event_counter => ++$event_counter,
    );

    if ($reason) {
        push @warnings, "Warning: line " . ($index + 1) . ": $reason";
        push @dry_output, 'x ' . $line if $dry_run;
        next;
    }

    if ($dry_run) {
        push @dry_output, $line;
        next;
    }

    push @events, $event;
    $body =~ s/(?<!\S)\@calendar(?!\S)/\@scheduled/g;
    $converted_lines{$index} = $body . $ending;
}

if ($dry_run) {
    my $dry_text = join '', @dry_output;
    print_dry_output($dry_text);
    print_stderr(join("\n", @warnings) . (@warnings ? "\n" : ''));
    print_stderr("Warnings: " . scalar(@warnings) . "\n");
    exit 0;
}

my @output_lines = map {
    exists $converted_lines{$_} ? $converted_lines{$_} : $lines[$_]
} 0 .. $#lines;
my $updated_todo = join '', @output_lines;

my $ics_dir = File::Spec->catdir(dirname($input_path), 'ics');
ensure_output_directory($ics_dir);

my ($base_name) = fileparse(basename($input_path), qr/\.[^.]*\z/);
my $output_path = File::Spec->catfile($ics_dir, $base_name . '.ics');
my $ics_text = make_calendar(\@events);
write_file_bytes($output_path, encode('UTF-8', $ics_text));

print STDOUT encode('UTF-8', $updated_todo)
    or fail("Cannot write updated todo.txt to stdout: $!", 1);
print_stderr(join("\n", @warnings) . (@warnings ? "\n" : ''));
print_stderr("Generated: " . scalar(@events) . " events\n");
print_stderr("Output: $output_path\n");
print_stderr("Warnings: " . scalar(@warnings) . "\n");

exit 0;

sub windows_arguments {
    my $loaded = eval { require Win32::API; 1 };
    fail("Unicode command-line support on Windows requires Win32::API: $@", 1)
        unless $loaded;

    my $get_command_line = Win32::API->new('kernel32', 'GetCommandLineW', '', 'N')
        or fail("Cannot load GetCommandLineW: $^E", 1);
    my $command_line = $get_command_line->Call()
        or fail("Cannot read the Windows command line: $^E", 1);

    my $count_buffer = pack('L', 0) . ("\0" x 4);
    my $command_line_to_argv = Win32::API->new(
        'shell32',
        'CommandLineToArgvW',
        'NP',
        'N',
    ) or fail("Cannot load CommandLineToArgvW: $^E", 1);
    my $argv_pointer = $command_line_to_argv->Call($command_line, $count_buffer)
        or fail("Cannot parse the Windows command line: $^E", 1);

    my @arguments;
    my $error;
    eval {
        my $argument_count = unpack 'L', $count_buffer;
        my $pointer_size = length pack 'p', undef;
        my $pointer_format = $pointer_size == 8 ? 'J' : 'L';
        my @wide_arguments;

        for my $index (0 .. $argument_count - 1) {
            my $argument_pointer = unpack $pointer_format, Win32::API::ReadMemory(
                $argv_pointer + $index * $pointer_size,
                $pointer_size,
            );
            push @wide_arguments, read_wide_string($argument_pointer);
        }

        my $argument_count_from_perl = scalar @ARGV;
        die "Windows and Perl argument counts do not match"
            if $argument_count_from_perl > @wide_arguments;
        @arguments = $argument_count_from_perl
            ? @wide_arguments[-$argument_count_from_perl .. -1]
            : ();
        1;
    } or $error = $@ || 'Unknown error while reading Windows arguments';

    my $local_free = Win32::API->new('kernel32', 'LocalFree', 'N', 'N')
        or fail("Cannot load LocalFree: $^E", 1);
    $local_free->Call($argv_pointer);
    fail("Cannot decode Windows command-line arguments: $error", 1) if $error;

    return @arguments;
}

sub windows_current_directory {
    my $get_directory = Win32::API->new('kernel32', 'GetCurrentDirectoryW', 'IP', 'I')
        or fail("Cannot load GetCurrentDirectoryW: $^E", 1);
    my $buffer_length = 260;
    while (1) {
        my $buffer = "\0" x ($buffer_length * 2);
        my $length = $get_directory->Call($buffer_length, $buffer);
        fail("Cannot get the current directory (Windows error " . Win32::GetLastError() . ")", 1)
            unless $length;
        if ($length >= $buffer_length) {
            $buffer_length = $length + 1;
            next;
        }
        return decode('UTF-16LE', substr($buffer, 0, $length * 2), FB_CROAK);
    }
}

sub read_wide_string {
    my ($pointer) = @_;
    my $bytes = '';
    for my $index (0 .. 32766) {
        my $character = Win32::API::ReadMemory($pointer + 2 * $index, 2);
        return decode('UTF-16LE', $bytes, FB_CROAK) if $character eq "\0\0";
        $bytes .= $character;
    }
    die "Windows command-line argument is not null-terminated";
}

sub ensure_output_directory {
    my ($directory) = @_;
    if ($^O ne 'MSWin32') {
        eval { make_path($directory) unless -d $directory; 1 }
            or fail("Cannot create '$directory': $@", 1);
        return;
    }

    my $wide_path = encode('UTF-16LE', $directory . "\0");
    my $get_attributes = Win32::API->new(
        'kernel32',
        'GetFileAttributesW',
        'P',
        'L',
    ) or fail("Cannot load GetFileAttributesW: $^E", 1);
    my $attributes = $get_attributes->Call($wide_path);
    return if defined $attributes && $attributes != 0xFFFFFFFF && ($attributes & 0x10);

    my $create_directory = Win32::API->new(
        'kernel32',
        'CreateDirectoryW',
        'PP',
        'I',
    ) or fail("Cannot load CreateDirectoryW: $^E", 1);
    return if $create_directory->Call($wide_path, 0);

    my $error = Win32::GetLastError();
    $attributes = $get_attributes->Call($wide_path);
    return if defined $attributes && $attributes != 0xFFFFFFFF && ($attributes & 0x10);
    fail("Cannot create '$directory' (Windows error $error)", 1);
}

sub read_file_bytes {
    my ($path) = @_;
    if ($^O ne 'MSWin32') {
        open my $input, '<:raw', $path
            or fail("Cannot open '$path': $!", 1);
        my $bytes = do { local $/; <$input> };
        close $input or fail("Cannot close '$path': $!", 1);
        return $bytes;
    }

    my $handle = create_file_handle($path, 0x80000000, 3);
    my $read_file = Win32::API->new('kernel32', 'ReadFile', 'NPIPP', 'I')
        or fail("Cannot load ReadFile: $^E", 1);
    my $bytes = '';
    while (1) {
        my $buffer = "\0" x (65536 + 8);
        my $count_buffer = pack('L', 0) . ("\0" x 4);
        unless ($read_file->Call($handle, $buffer, 65536, $count_buffer, 0)) {
            my $error = Win32::GetLastError();
            close_file_handle($handle, $path);
            fail("Cannot read '$path' (Windows error $error)", 1);
        }
        my $count = unpack 'L', $count_buffer;
        last unless $count;
        $bytes .= substr($buffer, 0, $count);
    }
    close_file_handle($handle, $path);
    return $bytes;
}

sub write_file_bytes {
    my ($path, $bytes) = @_;
    if ($^O ne 'MSWin32') {
        open my $output, '>:raw', $path
            or fail("Cannot open '$path' for writing: $!", 1);
        print {$output} $bytes or fail("Cannot write '$path': $!", 1);
        close $output or fail("Cannot close '$path': $!", 1);
        return;
    }

    my $handle = create_file_handle($path, 0x40000000, 2);
    my $write_file = Win32::API->new('kernel32', 'WriteFile', 'NPIPP', 'I')
        or fail("Cannot load WriteFile: $^E", 1);
    my $offset = 0;
    while ($offset < length $bytes) {
        my $chunk = substr($bytes, $offset, 65536);
        my $buffer = $chunk . ("\0" x 8);
        my $count_buffer = pack('L', 0) . ("\0" x 4);
        unless ($write_file->Call($handle, $buffer, length($chunk), $count_buffer, 0)) {
            my $error = Win32::GetLastError();
            close_file_handle($handle, $path);
            fail("Cannot write '$path' (Windows error $error)", 1);
        }
        my $count = unpack 'L', $count_buffer;
        unless ($count) {
            close_file_handle($handle, $path);
            fail("Cannot write '$path' (WriteFile returned zero bytes)", 1);
        }
        $offset += $count;
    }
    close_file_handle($handle, $path);
}

sub create_file_handle {
    my ($path, $access, $disposition) = @_;
    my $create_file = Win32::API->new('kernel32', 'CreateFileW', 'PIIPIIN', 'N')
        or fail("Cannot load CreateFileW: $^E", 1);
    my $handle = $create_file->Call(
        encode('UTF-16LE', $path . "\0"),
        $access,
        0x7,
        0,
        $disposition,
        0x80,
        0,
    );
    if (!defined $handle || $handle == -1) {
        my $error = Win32::GetLastError();
        my $action = $disposition == 3 ? 'open' : 'create';
        fail("Cannot $action '$path' (Windows error $error)", 1);
    }
    return $handle;
}

sub close_file_handle {
    my ($handle, $path) = @_;
    my $close_handle = Win32::API->new('kernel32', 'CloseHandle', 'N', 'I')
        or fail("Cannot load CloseHandle: $^E", 1);
    unless ($close_handle->Call($handle)) {
        my $error = Win32::GetLastError();
        fail("Cannot close '$path' (Windows error $error)", 1);
    }
}

sub split_line_ending {
    my ($line) = @_;
    if ($line =~ /\A(.*?)(\r\n|\n|\r)\z/s) {
        return ($1, $2);
    }
    return ($line, '');
}

sub build_event {
    my (%args) = @_;
    my @tokens = @{ $args{tokens} };

    my @due_tokens = grep { /\Adue:/ } @tokens;
    return (undef, 'due: is required') unless @due_tokens;
    return (undef, 'multiple due: values are not supported') if @due_tokens > 1;

    my $due = substr($due_tokens[0], 4);
    my $due_date = parse_date($due);
    return (undef, "invalid due: date '$due'") unless $due_date;

    my @start_tokens = grep { /\At:/ } @tokens;
    return (undef, 'multiple t: values are not supported') if @start_tokens > 1;

    my $start = $due;
    if (@start_tokens) {
        $start = substr($start_tokens[0], 2);
        return (undef, "invalid t: date '$start'") unless parse_date($start);
        return (undef, 't: is later than due:') if $start gt $due;
    }

    my $end = next_date($due_date);
    return (undef, "due: date '$due' cannot be represented with an exclusive DTEND")
        unless $end;

    my @categories = map { substr($_, 4) } grep { /\Acat:.+/ } @tokens;
    my $summary_date_index = 0;
    $summary_date_index++ while $summary_date_index <= $#tokens && $tokens[$summary_date_index] eq '';
    $summary_date_index++
        if defined $tokens[$summary_date_index] && $tokens[$summary_date_index] =~ /\A\([a-zA-Z]\)\z/;
    $summary_date_index = undef
        unless defined $tokens[$summary_date_index]
            && parse_date($tokens[$summary_date_index]);
    my @summary_parts;
    for my $index (0 .. $#tokens) {
        next if defined $summary_date_index && $index == $summary_date_index;
        my $token = $tokens[$index];
        next if $token eq '@calendar' || $token eq '@scheduled';
        next if $token =~ /\A(?:cat|t|due):/;
        next if $token =~ /\A\([a-zA-Z]\)\z/;
        next if $token =~ /\A\+/;
        push @summary_parts, $token;
    }
    my $summary = join ' ', @summary_parts;

    return ({
        start      => date_for_ics(parse_date($start)),
        end        => date_for_ics($end),
        summary    => $summary,
        categories => \@categories,
        uid        => sprintf(
            '%x-%x-%x-%x@todo2ics.local',
            time,
            $$,
            int(rand(0x7fffffff)),
            $args{event_counter},
        ),
    }, undef);
}

sub parse_date {
    my ($date) = @_;
    return unless $date =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/;
    my ($year, $month, $day) = ($1 + 0, $2 + 0, $3 + 0);
    return if $year < 1 || $month < 1 || $month > 12;

    my @month_days = (31, is_leap_year($year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    return if $day < 1 || $day > $month_days[$month - 1];
    return { year => $year, month => $month, day => $day };
}

sub is_leap_year {
    my ($year) = @_;
    return $year % 4 == 0 && ($year % 100 != 0 || $year % 400 == 0);
}

sub next_date {
    my ($date) = @_;
    my ($year, $month, $day) = @{$date}{qw(year month day)};
    my @month_days = (31, is_leap_year($year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);

    if ($day < $month_days[$month - 1]) {
        $day++;
    }
    elsif ($month < 12) {
        $month++;
        $day = 1;
    }
    elsif ($year < 9999) {
        $year++;
        $month = 1;
        $day = 1;
    }
    else {
        return;
    }

    return { year => $year, month => $month, day => $day };
}

sub date_for_ics {
    my ($date) = @_;
    return sprintf '%04d%02d%02d', @{$date}{qw(year month day)};
}

sub make_calendar {
    my ($events) = @_;
    my @lines = (
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID:-//todo2ics//EN',
        'CALSCALE:GREGORIAN',
    );

    my ($second, $minute, $hour, $day, $month, $year) = gmtime;
    my $dtstamp = sprintf '%04d%02d%02dT%02d%02d%02dZ',
        $year + 1900, $month + 1, $day, $hour, $minute, $second;

    for my $event (@$events) {
        push @lines,
            'BEGIN:VEVENT',
            'UID:' . $event->{uid},
            'DTSTAMP:' . $dtstamp,
            'DTSTART;VALUE=DATE:' . $event->{start},
            'DTEND;VALUE=DATE:' . $event->{end},
            'TRANSP:TRANSPARENT',
            'SUMMARY:' . escape_ics_text($event->{summary});
        if (@{ $event->{categories} }) {
            push @lines, 'CATEGORIES:' . join(
                ',',
                map { escape_ics_text($_) } @{ $event->{categories} },
            );
        }
        push @lines, 'END:VEVENT';
    }

    push @lines, 'END:VCALENDAR';
    return join("\r\n", map { fold_ics_line($_) } @lines) . "\r\n";
}

sub escape_ics_text {
    my ($text) = @_;
    $text =~ s/\\/\\\\/g;
    $text =~ s/\r\n|\r|\n/\\n/g;
    $text =~ s/;/\\;/g;
    $text =~ s/,/\\,/g;
    return $text;
}

sub fold_ics_line {
    my ($line) = @_;
    my $folded = '';
    my $bytes = 0;
    for my $character (split //, $line) {
        my $length = length encode('UTF-8', $character);
        if ($bytes + $length > 75) {
            $folded .= "\r\n ";
            $bytes = 1;
        }
        $folded .= $character;
        $bytes += $length;
    }
    return $folded;
}

sub print_stderr {
    my ($text) = @_;
    my $bytes;
    if ($^O eq 'MSWin32') {
        my ($encoding, $codepage, $error) = console_output_encoding();
        unless ($encoding) {
            $error =~ s/[^\x20-\x7E]/?/g;
            print STDERR "Cannot encode standard error: $error\n";
            exit 1;
        }
        $bytes = $encoding->encode($text);
    }
    else {
        $bytes = encode('UTF-8', $text);
    }
    print STDERR $bytes or exit 1;
}

sub print_dry_output {
    my ($text) = @_;
    my $bytes;
    if ($^O eq 'MSWin32') {
        my ($encoding, $codepage, $error) = console_output_encoding();
        fail($error, 1) unless $encoding;
        $bytes = eval { $encoding->encode($text, FB_CROAK) };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+\z//;
            fail("Cannot encode --dry output using code page $codepage: $error", 1);
        }
    }
    else {
        $bytes = encode('UTF-8', $text);
    }
    print STDOUT $bytes or fail("Cannot write dry-run output: $!", 1);
}

sub console_output_encoding {
    my $get_codepage = Win32::API->new('kernel32', 'GetConsoleOutputCP', '', 'I')
        or return (undef, undef, "Cannot load GetConsoleOutputCP: $^E");
    my $codepage = $get_codepage->Call()
        or return (undef, undef, "Cannot determine the Windows console output code page: $^E");
    my $encoding_name = $codepage == 65001 ? 'UTF-8' : "cp$codepage";
    my $encoding = find_encoding($encoding_name)
        or return (undef, undef, "Unsupported Windows console output code page: $codepage");
    return ($encoding, $codepage, undef);
}

sub fail {
    my ($message, $status) = @_;
    print_stderr($message . "\n");
    exit $status;
}
