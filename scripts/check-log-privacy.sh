#!/usr/bin/env bash
# Fails on a value logged as public that isn't plainly safe. Every `privacy: .public` interpolation, and every
# interpolation in the message of an `EngineLog` call (logged as public by the wrapper), must have one of the safe
# shapes below, or be listed as a reviewed exception. A message passed to `EngineLog` must be a string literal.
# Anything else (error text, descriptions, paths, URLs, prompts, server messages) is logged as private.
set -euo pipefail
cd "$(dirname "$0")/.."

files=()
while IFS= read -r -d '' file; do files+=("$file"); done < <(
    find JutsuStudio JutsuCLI Packages -name '*.swift' -not -path '*/.build/*' -print0 | sort -z
)

perl -e '
use strict;
use warnings;

# Safe shapes of a public value, matched against the whole expression with spaces collapsed and a trailing
# `?? "literal"` fallback removed.
my @safe = (
    qr/^[\w.]+\.count$/,              # a count
    qr/^(?:[\w.]+\.)?\w*Count$/,      # a variable holding one
    qr/^Int\(.*\)$/,                  # a number made an integer
    qr/^[\w.]+ [+-] \d+$/,            # a number plus or minus a constant (attempt + 1)
    qr/^(?:[\w.]+\.)?(?:id|\w*ID)$/,  # an ID: of a job, record, request or correlation
    qr/^(?:[\w.]+\.)?(?:model|modelID|toolName)$/,  # a model or tool name
    qr/^(?:[\w.]+\.)?(?:method|statusCode|host)$/,  # an HTTP method, status or host
    qr/\.rawValue$/,                  # an enum case
);

# Reviewed exceptions: "file|expression", each with why it is safe.
my %reviewed = map { $_ => 1 } (
    # The name of the font the app bundles.
    "JutsuStudio/DesignSystem/Theme.swift|name",
    # Model IDs and their limits from models_explore.
    "JutsuStudio/Create/AppEnvironment+ModelConstraints.swift|difference",
    # REST routes on the API host, whose only variable part is a request ID.
    "Packages/HiggsfieldKit/Sources/HiggsfieldAPI/HiggsfieldAPIClient.swift|path",
    # The wrapper itself; its callers are checked below.
    "Packages/JutsuKit/Sources/JutsuCore/EngineLog.swift|message",
    # Numbers of variants and submits.
    "Packages/JutsuKit/Sources/JobEngine/JobEngine+Variants.swift|asked",
    "Packages/JutsuKit/Sources/JobEngine/JobEngine+Variants.swift|started",
    "Packages/JutsuKit/Sources/JobEngine/JobEngine.swift|unanswered",
);

my $failed = 0;

sub line_of { my ($text, $at) = @_; return 1 + (substr($text, 0, $at) =~ tr/\n//); }

# The text from just after the "(" at $start up to its matching ")", skipping string literals; undef if unclosed.
sub balanced {
    my ($text, $start) = @_;
    my ($depth, $quoted) = (1, 0);
    for (my $i = $start; $i < length $text; $i++) {
        my $c = substr($text, $i, 1);
        if ($quoted) {
            if ($c eq "\\") { $i++ } elsif ($c eq "\"") { $quoted = 0 }
            next;
        }
        if ($c eq "\"") { $quoted = 1 }
        elsif ($c eq "(") { $depth++ }
        elsif ($c eq ")") { return substr($text, $start, $i - $start) if --$depth == 0 }
    }
    return undef;
}

# The interpolation up to its first top-level comma: the value, without `privacy:` or `format:`.
sub value_of {
    my ($inner) = @_;
    my ($depth, $quoted) = (0, 0);
    for (my $i = 0; $i < length $inner; $i++) {
        my $c = substr($inner, $i, 1);
        if ($quoted) {
            if ($c eq "\\") { $i++ } elsif ($c eq "\"") { $quoted = 0 }
            next;
        }
        if ($c eq "\"") { $quoted = 1 }
        elsif ($c =~ /[(\[]/) { $depth++ }
        elsif ($c =~ /[)\]]/) { $depth-- }
        elsif ($c eq "," && $depth == 0) { return substr($inner, 0, $i) }
    }
    return $inner;
}

sub check {
    my ($file, $line, $value, $why) = @_;
    $value =~ s/\s+/ /g;
    $value =~ s/^ | $//g;
    my $shape = $value;
    $shape =~ s/ ?\?\? "[^"]*"$//;
    return if $reviewed{"$file|$value"};
    return if grep { $shape =~ $_ } @safe;
    print "$file:$line: $value $why\n";
    $failed = 1;
}

for my $file (@ARGV) {
    open my $fh, "<", $file or die "$file: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    # Every interpolation with `privacy: .public`, wherever its line breaks fall.
    while ($text =~ /\\\(/g) {
        my $at = pos($text);
        my $inner = balanced($text, $at);
        next unless defined $inner && $inner =~ /\bprivacy:\s*\.public\b/;
        check($file, line_of($text, $at), value_of($inner), "is logged with privacy: .public");
    }

    # EngineLog logs its message as public: it must be a literal, and what it interpolates must be safe.
    next unless $file =~ m{/(?:JobEngine|Presentation)/};
    while ($text =~ /\blog\.(?:error|fault)\(\s*/g) {
        my $at = pos($text);
        if (substr($text, $at, 1) ne "\"" || substr($text, $at, 3) eq "\"\"\"") {
            print "$file:" . line_of($text, $at) . ": EngineLog message is not a one-line string literal\n";
            $failed = 1;
            next;
        }
        my $i = $at + 1;
        while ($i < length $text) {
            my $c = substr($text, $i, 1);
            last if $c eq "\"" || $c eq "\n";
            if (substr($text, $i, 2) eq "\\(") {
                my $inner = balanced($text, $i + 2);
                last unless defined $inner;
                check($file, line_of($text, $i), value_of($inner), "is interpolated into an EngineLog message");
                $i += 2 + length($inner) + 1;
                next;
            }
            $i += $c eq "\\" ? 2 : 1;
        }
    }
}

if ($failed) {
    print "Log it with privacy: .private (EngineLog: pass it as detail), or add a reviewed exception to this script\n";
    exit 1;
}
' "${files[@]}"
