#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/lib";

use TinyLLM;

# Autoflush STDOUT for interactive feel
select(STDOUT);
$| = 1;

# Optional: allow a custom model path via --model=... or ALITA_LLM_PATH
my $model_path = $ENV{ALITA_LLM_PATH} // 'myBrainLLM.dat';
for my $arg (@ARGV) {
    if ($arg =~ /^--model=(.+)$/) {
        $model_path = $1;
    }
}

my $llm = TinyLLM->new(path => $model_path);

# Ensure we persist on normal exit and when interrupted
END {
    eval { $llm && $llm->save(); 1 } or do {
        my $err = $@ || 'Unknown error';
        warn "Failed to save LLM: $err\n";
    };
}

$SIG{INT}  = sub { $llm->save(); print "Saved model. Bye.\n"; exit 0; };
$SIG{TERM} = sub { $llm->save(); print "Saved model. Bye.\n"; exit 0; };

# Read conversational input from STDIN, train, and emit a small reply
while (defined(my $line = <STDIN>)) {
    chomp $line;

    # Train on any input (including empty lines) so user can "prime" the model
    $llm->train($line // '');

    my $reply = $llm->reply(
        prompt      => $line // '',
        max_tokens  => 40,
        temperature => 0.9,
    );

    # Fallback if the model cannot yet produce a token
    $reply = '...' if !defined($reply) || $reply eq '';

    print "$reply\n";
}

# On EOF, normal exit triggers END { $llm->save() }
exit 0;
