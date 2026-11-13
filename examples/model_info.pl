#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Spec;
use Getopt::Long qw(GetOptions);
use JSON::PP;
use TinyLLM;

my $model_path = File::Spec->catfile($FindBin::RealBin, '..', 'myBrainLLM.dat');
my ($json, $help) = (0, 0);
GetOptions(
    'model=s' => \$model_path,
    'json' => \$json,
    'help|h' => \$help,
) or usage(2);
usage(0) if $help;
die "Unexpected arguments: @ARGV\n" if @ARGV;
die "Model not found: $model_path\n" if !-f $model_path;

my $model = TinyLLM->new(path => $model_path);
my $stats = $model->stats();
$stats->{file_bytes} = -s $model_path;

if ($json) {
    print JSON::PP->new->canonical->pretty->encode($stats);
    exit 0;
}

print "Model: $model_path\n";
printf "Saved file: %d bytes (%.2f KiB)\n", $stats->{file_bytes}, $stats->{file_bytes} / 1024;
printf "Current state if saved: %d bytes (%.2f KiB)\n",
    $stats->{serialized_bytes}, $stats->{serialized_bytes} / 1024;
printf "Model cap: %d bytes (%.2f GB, %.2f GiB)\n",
    $stats->{max_model_bytes},
    $stats->{max_model_bytes} / 1_000_000_000,
    $stats->{max_model_bytes} / (1024 ** 3);
print "TinyLLM version: $stats->{version}\n";
print "Text: $stats->{vocabulary_size} words, $stats->{bigram_count} unique transitions, "
    . "$stats->{total_tokens} trained tokens (including boundaries)\n";
print "Memory: $stats->{memory_count} entries; "
    . "$stats->{knowledge_sources} unique file sources\n";

if (my $classifier = $stats->{classifier}) {
    print "Classifier: $classifier->{algorithm}\n";
    print "Features: $classifier->{feature_count}; labels: $classifier->{label_count}; "
        . "threshold: $classifier->{threshold}\n";
    print "Training examples: $classifier->{total_examples}\n";
    print "Stored feature counts: $classifier->{stored_feature_counts}\n";
    print "Examples by label:\n";
    for my $label (sort keys %{$classifier->{examples_by_label}}) {
        print "  $label: $classifier->{examples_by_label}{$label}\n";
    }
} else {
    print "Classifier: not trained\n";
}

sub usage {
    my ($status) = @_;
    print <<'USAGE';
Inspect a TinyLLM model without modifying it.

Usage:
  perl examples/model_info.pl [--model=PATH] [--json]

  --model=PATH  Existing model (default: project-root myBrainLLM.dat)
  --json        Print machine-readable metadata, limits, memories, and counts
  --help        Show this message

Saved file size describes the file on disk. Current-state size describes what
the loaded model would save, including current version/path metadata. Loading
an older model or a copied file can therefore make these two sizes differ.
USAGE
    exit $status;
}
