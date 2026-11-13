#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Spec;
use Getopt::Long qw(GetOptions);
use Alita::Agent;
use TinyLLM;

my $model_path = File::Spec->catfile($FindBin::RealBin, 'alita-chat-demo.dat');
my $knowledge_path = File::Spec->catfile($FindBin::RealBin, 'knowledge', 'alita-notes.txt');
my ($max_model_bytes, $help);
GetOptions(
    'model=s' => \$model_path,
    'knowledge=s' => \$knowledge_path,
    'max-model-bytes=s' => \$max_model_bytes,
    'help|h' => \$help,
) or usage(2);
usage(0) if $help;
die "Unexpected arguments: @ARGV\n" if @ARGV;
binmode STDOUT, ':encoding(UTF-8)' or die "Could not configure output: $!\n";

my %options = (path => $model_path);
$options{max_model_bytes} = $max_model_bytes if defined $max_model_bytes;
my $model = TinyLLM->new(%options);
my $alita = Alita::Agent->new(model => $model);

print $alita->teach(prompt => 'Who are you?', response => 'I am Alita, your local learning assistant.'), "\n";
say_turn('Who are you?');
say_turn('My favorite constellation is Orion.');
say_turn('What is my favorite constellation?');

# The caller names exactly one file. Content is knowledge, never executable
# instructions. Importing the identical file again is a successful no-op.
my $import = $alita->ingest_file($knowledge_path);
printf "%s: %s (%d %s)\n",
    $import->{duplicate} ? 'Already imported' : 'Imported',
    $import->{source}, $import->{chunks}, $import->{chunks} == 1 ? 'chunk' : 'chunks';
say_turn('Which city hosts the Lantern workshop?');

# Library clients explicitly save; the interactive CLI instead autosaves.
$model->save;
my $stats = $model->stats;
printf "Saved %s: %d bytes of %d allowed; %d memories, %d sources\n",
    $model_path, $stats->{serialized_bytes}, $stats->{max_model_bytes},
    $stats->{memory_count}, $stats->{knowledge_sources};

sub say_turn {
    my ($prompt) = @_;
    print "You: $prompt\nAlita: ", $alita->chat($prompt), "\n";
}

sub usage {
    my ($status) = @_;
    print <<'USAGE';
Demonstrate local conversation learning, teaching, and explicit file knowledge.

Usage: perl examples/conversation.pl [options]
  --model=PATH             Saved model (default: examples/alita-chat-demo.dat)
  --knowledge=PATH         One UTF-8 text file (default: bundled example notes)
  --max-model-bytes=N      Smaller saved-state budget, never above 4000000000
  --help                   Show this help

The default model is ignored by Git. Repeated runs add conversation and teaching
counts to it; an identical source file is not imported twice. Custom files may
not answer the bundled demonstration question. No network or shell is used.
USAGE
    exit $status;
}
