use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(abs_path getcwd);
use FindBin;
use IPC::Open3 qw(open3);
use Storable qw(retrieve);

# Determine the project and command paths before changing directories.
my $project_root = abs_path(File::Spec->catdir($FindBin::RealBin, '..'));
my $alita_path   = File::Spec->catfile($project_root, 'alitaLLM.pl');

ok(-e $alita_path, 'alitaLLM.pl exists at project root');

# Work in an isolated temp directory so myBrainLLM.dat doesn't pollute the repo
my $tmpdir = tempdir(CLEANUP => 1);
ok(-d $tmpdir, 'created temporary working directory');

# Helper to run a conversational session with alitaLLM.pl
my $session_number = 0;
sub run_alita_session {
    my (@inputs) = @_;

    # Run from tmpdir so the LLM file (default myBrainLLM.dat) is written here
    my $orig_cwd = getcwd();
    chdir $tmpdir or die "Failed to chdir to $tmpdir: $!";

    $session_number++;
    my $input_path = File::Spec->catfile($tmpdir, "input-$session_number.txt");
    my $output_path = File::Spec->catfile($tmpdir, "output-$session_number.txt");
    my $error_path = File::Spec->catfile($tmpdir, "error-$session_number.txt");

    open my $input_writer, '>', $input_path
        or die "Failed to write $input_path: $!";
    for my $line (@inputs) {
        print {$input_writer} $line, "\n";
    }
    close $input_writer or die "Failed to close $input_path: $!";

    # Pass regular filehandles directly to the child. Avoid pipe EOF issues
    # on Windows and shell expansion of characters in workspace paths.
    open my $input_reader, '<', $input_path or die "Failed to read $input_path: $!";
    open my $output_writer, '>', $output_path or die "Failed to write $output_path: $!";
    open my $error_writer, '>', $error_path or die "Failed to write $error_path: $!";
    my $pid = open3(
        ['&', $input_reader], ['&', $output_writer], ['&', $error_writer],
        $^X, $alita_path,
    );
    waitpid($pid, 0);
    my $status = $? >> 8;
    close $output_writer;
    close $error_writer;

    open my $output_reader, '<', $output_path
        or die "Failed to read $output_path: $!";
    my $stdout = do { local $/; <$output_reader> // '' };
    close $output_reader;

    open my $error_reader, '<', $error_path
        or die "Failed to read $error_path: $!";
    my $stderr = do { local $/; <$error_reader> // '' };
    close $error_reader;

    chdir $orig_cwd or die "Failed to chdir back to $orig_cwd: $!";

    return ($stdout, $stderr, $status);
}

subtest 'initial conversation creates myBrainLLM.dat' => sub {
    my ($out, $err, $status) = run_alita_session(
        "Hello there!",
        "I like learning from conversations.",
    );

    is($status, 0, 'alitaLLM.pl exited successfully');
    ok(length($out) > 0, 'alitaLLM.pl produced output');
    my $llm_path = File::Spec->catfile($tmpdir, 'myBrainLLM.dat');
    ok(-e $llm_path, 'LLM file created');
    ok(-s $llm_path > 0, 'LLM file is non-empty');
};

subtest 'subsequent conversation updates/persists model' => sub {
    my $llm_path = File::Spec->catfile($tmpdir, 'myBrainLLM.dat');
    ok(-e $llm_path, 'LLM exists before second run');
    my $tokens_before = retrieve($llm_path)->{total_tokens};

    my ($out2, $err2, $status2) = run_alita_session(
        "This is another training sentence.",
        "Goodbye."
    );

    is($status2, 0, 'alitaLLM.pl exited successfully on second run');
    ok(length($out2) > 0, 'alitaLLM.pl produced output on second run');
    ok(-e $llm_path, 'LLM still exists after second run');
    my $tokens_after = retrieve($llm_path)->{total_tokens};
    cmp_ok(
        $tokens_after,
        '>',
        $tokens_before,
        'second session persists additional training tokens',
    );
};

done_testing();
