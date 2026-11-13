use strict;
use warnings;
use Test::More;
use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3 qw(open3);
use lib "$FindBin::RealBin/../lib";
use TinyLLM;

my $directory = tempdir(CLEANUP => 1);
my $script = abs_path(File::Spec->catfile($FindBin::RealBin, '..', 'examples', 'conversation.pl'));
my $model_path = File::Spec->catfile($directory, 'demo.dat');
my ($output, $status) = run_example('--help', "--model=$model_path");
is($status, 0, 'conversation example help succeeds');
like($output, qr/--knowledge=PATH/, 'help documents explicit source selection');
ok(!-e $model_path, 'help does not create a model');

($output, $status) = run_example("--model=$model_path");
is($status, 0, 'the self-contained conversation example runs');
like($output, qr/Alita: I am Alita, your local learning assistant\./, 'example recalls an exact teaching');
like($output, qr/Earlier you said:.*My favorite constellation is Orion/, 'example recalls conversational learning');
like($output, qr/From .*alita-notes\.txt: The Lantern workshop is hosted in Tempe/, 'example cites imported knowledge');
ok(-s $model_path, 'example saves its model');
my $first_stats = TinyLLM->new(path => $model_path)->stats;
is($first_stats->{knowledge_sources}, 1, 'example persists one source');
is($first_stats->{max_model_bytes}, 4_000_000_000, 'example observes the 4 GB ceiling');

($output, $status) = run_example("--model=$model_path");
is($status, 0, 'example can continue an existing model');
like($output, qr/Already imported: .*alita-notes\.txt/, 'second run deduplicates the source');
is(TinyLLM->new(path => $model_path)->stats->{knowledge_sources}, 1, 'rerunning does not add a duplicate source');
done_testing;

sub run_example {
    my (@arguments) = @_;
    my $input_path = File::Spec->catfile($directory, 'input.txt');
    my $output_path = File::Spec->catfile($directory, 'output.txt');
    my $error_path = File::Spec->catfile($directory, 'error.txt');
    open my $empty, '>:raw', $input_path or die $!;
    close $empty or die $!;
    open my $input, '<:raw', $input_path or die $!;
    open my $out, '>:raw', $output_path or die $!;
    open my $err, '>:raw', $error_path or die $!;
    my $pid = open3(['&', $input], ['&', $out], ['&', $err], $^X, $script, @arguments);
    waitpid($pid, 0);
    my $status = $? >> 8;
    close $out;
    close $err;
    open my $reader, '<:encoding(UTF-8)', $output_path or die $!;
    my $output = do { local $/; <$reader> // '' };
    close $reader;
    if ($status) {
        open my $errors, '<', $error_path or die $!;
        diag do { local $/; <$errors> // '' };
        close $errors;
    }
    return ($output, $status);
}
