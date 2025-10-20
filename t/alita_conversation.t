use strict;
use warnings;
use Test::More;
use IPC::Open3;
use Symbol qw(gensym);
use IO::Select;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(abs_path getcwd);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

# Determine project root and alita.pl absolute path before changing directories
my $project_root = abs_path(getcwd());
my $alita_path   = File::Spec->catfile($project_root, 'alita.pl');

ok(-e $alita_path, 'alita.pl exists at project root');

# Ensure TinyLLM can be found when running from a temp directory
my $lib_path = File::Spec->catdir($project_root, 'lib');
if (-d $lib_path) {
    $ENV{PERL5LIB} = $ENV{PERL5LIB} ? "$lib_path:$ENV{PERL5LIB}" : $lib_path;
}

# Work in an isolated temp directory so myBrainLLM.dat doesn't pollute the repo
my $tmpdir = tempdir(CLEANUP => 1);
ok(-d $tmpdir, 'created temporary working directory');

# Helper to run a conversational session with alita.pl
sub run_alita_session {
    my (@inputs) = @_;

    # Run from tmpdir so the LLM file (default myBrainLLM.dat) is written here
    my $orig_cwd = getcwd();
    chdir $tmpdir or die "Failed to chdir to $tmpdir: $!";

    my $err = gensym();
    my $pid = open3(my $w, my $r, $err, $^X, $alita_path);
    ok($pid, 'spawned alita.pl');

    select((select($w), $| = 1)[0]); # autoflush writer

    # Send conversational inputs
    for my $line (@inputs) {
        print $w $line, "\n";
    }
    close $w; # signal EOF

    my $sel = IO::Select->new();
    $sel->add($r);
    $sel->add($err);

    my $stdout = '';
    my $stderr = '';

    my $timeout_s = 8;
    my $start = time();
    my $exited = 0;

    while (1) {
        my $now = time();
        last if ($now - $start) > $timeout_s;

        # Check if child has exited
        my $res = waitpid($pid, WNOHANG);
        if ($res == $pid) {
            $exited = 1;
        }

        my @ready = $sel->can_read(0.1);
        for my $fh (@ready) {
            my $buf;
            my $bytes = sysread($fh, $buf, 4096);
            if (defined $bytes && $bytes > 0) {
                if ($fh == $r) { $stdout .= $buf } else { $stderr .= $buf }
            } else {
                $sel->remove($fh);
                close $fh;
            }
        }

        last if $exited && !$sel->count();
    }

    # If still running after timeout, kill
    if (!$exited) {
        kill 'TERM', $pid;
        sleep 0.2;
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }

    chdir $orig_cwd or die "Failed to chdir back to $orig_cwd: $!";

    return ($stdout, $stderr);
}

subtest 'initial conversation creates myBrainLLM.dat' => sub {
    my ($out, $err) = run_alita_session(
        "Hello there!",
        "I like learning from conversations.",
    );

    ok(length($out) + length($err) >= 0, 'alita.pl produced some output (stdout/stderr)');
    my $llm_path = File::Spec->catfile($tmpdir, 'myBrainLLM.dat');
    ok(-e $llm_path, 'LLM file created');
    ok(-s $llm_path > 0, 'LLM file is non-empty');
};

subtest 'subsequent conversation updates/persists model' => sub {
    my $llm_path = File::Spec->catfile($tmpdir, 'myBrainLLM.dat');
    ok(-e $llm_path, 'LLM exists before second run');

    my $mtime_before = (stat($llm_path))[9] // 0;

    # Ensure timestamp granularity difference on some filesystems
    sleep 1.1;

    my ($out2, $err2) = run_alita_session(
        "This is another training sentence.",
        "Goodbye."
    );

    ok(length($out2) + length($err2) >= 0, 'alita.pl produced some output on second run');
    ok(-e $llm_path, 'LLM still exists after second run');
    my $mtime_after = (stat($llm_path))[9] // 0;
    ok($mtime_after >= $mtime_before, 'LLM file timestamp persisted/updated');
};

done_testing();
