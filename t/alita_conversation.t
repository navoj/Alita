use strict;
use warnings;
use utf8;
use Test::More;
use Digest::SHA ();
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(abs_path getcwd);
use FindBin;
use IPC::Open3 qw(open3);
use Storable qw(retrieve);
use lib "$FindBin::RealBin/../lib";

use TinyLLM;

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
    my $options = ref($_[0]) eq 'HASH' ? shift : {};
    my (@inputs) = @_;

    # Run from tmpdir so the LLM file (default myBrainLLM.dat) is written here
    my $orig_cwd = getcwd();
    my $working_directory = $options->{cwd} // $tmpdir;
    chdir $working_directory
        or die "Failed to chdir to $working_directory: $!";

    $session_number++;
    my $input_path = File::Spec->catfile($tmpdir, "input-$session_number.txt");
    my $output_path = File::Spec->catfile($tmpdir, "output-$session_number.txt");
    my $error_path = File::Spec->catfile($tmpdir, "error-$session_number.txt");

    open my $input_writer, '>:encoding(UTF-8)', $input_path
        or die "Failed to write $input_path: $!";
    for my $line (@inputs) {
        print {$input_writer} $line, "\n";
    }
    close $input_writer or die "Failed to close $input_path: $!";

    # Pass regular filehandles directly to the child. Avoid pipe EOF issues
    # on Windows and shell expansion of characters in workspace paths.
    open my $input_reader, '<:raw', $input_path
        or die "Failed to read $input_path: $!";
    open my $output_writer, '>:raw', $output_path
        or die "Failed to write $output_path: $!";
    open my $error_writer, '>:raw', $error_path
        or die "Failed to write $error_path: $!";
    local $ENV{ALITA_LLM_PATH};
    delete $ENV{ALITA_LLM_PATH};
    my $environment = $options->{environment} // {};
    if (exists $environment->{ALITA_LLM_PATH}) {
        $ENV{ALITA_LLM_PATH} = $environment->{ALITA_LLM_PATH};
    }
    my @arguments = @{$options->{arguments} // []};
    my $pid = open3(
        ['&', $input_reader], ['&', $output_writer], ['&', $error_writer],
        $^X, $alita_path, @arguments,
    );
    waitpid($pid, 0);
    my $status = $? >> 8;
    close $output_writer;
    close $error_writer;

    open my $output_reader, '<:encoding(UTF-8)', $output_path
        or die "Failed to read $output_path: $!";
    my $stdout = do { local $/; <$output_reader> // '' };
    close $output_reader;

    open my $error_reader, '<:encoding(UTF-8)', $error_path
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

subtest 'help and option validation do not create a model' => sub {
    my $help_model = File::Spec->catfile($tmpdir, 'help-model.dat');
    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$help_model", '--help'] },
    );
    is($status, 0, '--help succeeds');
    like($out, qr/--max-model-bytes/, 'help documents the model budget');
    like($out, qr{/teach question => answer}, 'help documents teaching');
    like($out, qr{/read PATH}, 'help documents explicit file reading');
    unlike($out, qr/(?:You|Alita):/, 'piped help has no interactive prompts');
    ok(!-e $help_model, '--help does not create a model');

    ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$help_model", '--max-model-bytes=4000000001'] },
    );
    isnt($status, 0, 'the hard model-size ceiling is enforced');
    like($err, qr/max-model-bytes.*4000000000/s, 'cap error states the ceiling');
    ok(!-e $help_model, 'invalid options do not create a model');
};

subtest 'teach is recalled after restart and read-only commands stay read-only' => sub {
    my $model_path = File::Spec->catfile($tmpdir, 'taught-model.dat');
    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        '/teach What is the launch code? => cerulean-47',
        '/stats',
        '/quit',
    );
    is($status, 0, 'teaching session succeeds') or diag $err;
    like(
        $out,
        qr/^Learned response for: What is the launch code\?$/m,
        'teach reports its acknowledgement',
    );
    like($out, qr/^Memories: 1$/m, 'stats report the stored teaching');
    ok(-s $model_path, 'teach autosaves the model');

    my $tokens_after_teach = TinyLLM->new(
        path => $model_path,
    )->stats()->{total_tokens};
    ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        'What is the launch code?',
        '/quit',
    );
    is($status, 0, 'restart conversation succeeds') or diag $err;
    like($out, qr/^cerulean-47$/m, 'the exact taught answer is recalled');
    unlike($out, qr/(?:You|Alita):/, 'piped chat has no banner or prompts');
    cmp_ok(
        TinyLLM->new(path => $model_path)->stats()->{total_tokens},
        '>',
        $tokens_after_teach,
        'the recalled conversation turn is also learned and saved',
    );

    my $digest_before_read_only_commands = file_digest($model_path);
    ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        '/help',
        '/stats',
        '/sources',
        '/quit',
    );
    is($status, 0, 'read-only command session succeeds') or diag $err;
    like($out, qr/^Commands:$/m, '/help emits command help');
    like($out, qr/^No imported sources\.$/m, '/sources handles an empty list');
    is(
        file_digest($model_path),
        $digest_before_read_only_commands,
        'help, stats, sources, and quit do not rewrite a clean model',
    );
};

subtest 'quoted read paths persist sources and support recall' => sub {
    my $model_path = File::Spec->catfile($tmpdir, 'file-knowledge.dat');
    my $document_path = File::Spec->catfile(
        $tmpdir,
        'facts with spaces.txt',
    );
    write_text(
        $document_path,
        "Neon foxes sleep under copper moons.\n"
            . "Their observatory is called Lantern Ridge.\n",
    );

    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        qq{/read "$document_path"},
        '/sources',
        '/quit',
    );
    is($status, 0, 'quoted path import succeeds') or diag $err;
    like($out, qr/^Imported: .*facts with spaces\.txt/m, 'read reports import');
    like($out, qr/^Source: .*facts with spaces\.txt/m, 'sources lists the file');
    my $stats = TinyLLM->new(path => $model_path)->stats();
    is($stats->{knowledge_sources}, 1, 'the file source is persisted');
    cmp_ok($stats->{memory_count}, '>=', 1, 'the file produced persisted memory');

    my $digest_before_duplicate = file_digest($model_path);
    ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        qq{/read "$document_path"},
        '/sources',
        '/quit',
    );
    is($status, 0, 'duplicate import is a successful no-op') or diag $err;
    like($out, qr/^Already imported: .*facts with spaces\.txt/m, 'duplicate is clear');
    is(
        file_digest($model_path),
        $digest_before_duplicate,
        'duplicate import and source listing do not rewrite the model',
    );

    ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        'Where do neon foxes sleep?',
        '/quit',
    );
    is($status, 0, 'file recall after restart succeeds') or diag $err;
    like(
        $out,
        qr/Neon foxes sleep under copper moons\./,
        'a query recalls imported file content after restart',
    );
};

subtest 'UTF-8 teaching, input, output, and file recall survive restart' => sub {
    my $model_path = File::Spec->catfile($tmpdir, 'utf8-model.dat');
    my $document_path = File::Spec->catfile($tmpdir, 'utf8-facts.txt');
    write_text(
        $document_path,
        "La astrónoma Zoë observa la nebulosa jalapeño desde Mérida.\n",
    );

    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        '/teach ¿Cuál es el color favorito de José? => azul añil',
        qq{/read "$document_path"},
        '/quit',
    );
    is($status, 0, 'UTF-8 teaching and import succeed') or diag $err;
    like($out, qr/José/, 'UTF-8 acknowledgement is emitted intact');
    unlike($err, qr/Wide character/i, 'UTF-8 output emits no wide-character warning');

    ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        '¿Cuál es el color favorito de José?',
        '¿Dónde observa la astrónoma Zoë?',
        '/quit',
    );
    is($status, 0, 'UTF-8 recall after restart succeeds') or diag $err;
    like($out, qr/^azul añil$/m, 'non-ASCII taught response round-trips');
    like(
        $out,
        qr/astrónoma Zoë observa la nebulosa jalapeño desde Mérida/,
        'non-ASCII file keywords and response round-trip',
    );
    unlike($err, qr/Wide character/i, 'UTF-8 recall emits no encoding warning');
};

subtest 'whitespace-only input is ignored' => sub {
    my $model_path = File::Spec->catfile($tmpdir, 'blank-input.dat');
    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        '',
        '   ',
        "\t",
        '/quit',
    );
    is($status, 0, 'blank input does not become a chat error') or diag $err;
    unlike($err, qr/chat text must not be empty/, 'blank input never reaches Agent chat');
    is($out, "Bye.\n", 'blank piped turns emit no replies or prompts');
    ok(!-e $model_path, 'blank turns and quit do not create a model');
};

subtest 'failed imports preserve state and the session continues' => sub {
    my $model_path = File::Spec->catfile($tmpdir, 'file-knowledge.dat');
    my $document_path = File::Spec->catfile(
        $tmpdir,
        'facts with spaces.txt',
    );
    my $digest_before_failure = file_digest($model_path);
    my ($out, $err, $status) = run_alita_session(
        {
            arguments => [
                "--model=$model_path",
                '--max-file-bytes=10',
            ],
        },
        qq{/read "$document_path"},
        '/sources',
        '/quit',
    );
    isnt($status, 0, 'oversized import makes the session status nonzero');
    like($err, qr/exceeds the 10-byte limit/, 'failed import explains the cap');
    like(
        $out,
        qr/^Source: .*facts with spaces\.txt/m,
        'the session continues and can use existing knowledge',
    );
    is(
        file_digest($model_path),
        $digest_before_failure,
        'failed import and later read-only commands do not rewrite state',
    );
};

subtest 'bare paths remain conversation instead of implicit file access' => sub {
    my $model_path = File::Spec->catfile($tmpdir, 'file-knowledge.dat');
    my $bare_path = File::Spec->catfile($tmpdir, 'not implicitly read.txt');
    write_text($bare_path, "This content must not be imported implicitly.\n");
    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        $bare_path,
        '/sources',
        '/quit',
    );
    is($status, 0, 'a bare path is accepted as ordinary chat') or diag $err;
    unlike($out, qr/^Imported:/m, 'bare paths do not invoke file import');
    unlike(
        $out,
        qr/^Source: .*not implicitly read\.txt/m,
        'bare path is absent from imported sources',
    );
    is(
        TinyLLM->new(path => $model_path)->stats()->{knowledge_sources},
        1,
        'implicit path text does not add a knowledge source',
    );
};

subtest 'invalid commands are errors and are never learned' => sub {
    my $model_path = File::Spec->catfile($tmpdir, 'invalid-commands.dat');
    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$model_path"] },
        '/unknown',
        '/teach missing delimiter',
        '/read "',
        '/stats unexpected',
        '/quit',
    );
    isnt($status, 0, 'invalid command session exits nonzero');
    like($err, qr/Unknown command '\/unknown'/, 'unknown command is diagnosed');
    like($err, qr{Usage: /teach question => answer}, 'malformed teaching is diagnosed');
    like($err, qr/Malformed quoted path/, 'malformed read path is diagnosed');
    like($err, qr{/stats does not accept arguments}, 'extra command args are rejected');
    like($out, qr/^Bye\.$/m, 'processing continues through a later quit command');
    ok(!-e $model_path, 'invalid and read-only commands create no model');
};

subtest 'explicit save, exit alias, and save failure behavior' => sub {
    my $explicit_save_path = File::Spec->catfile(
        $tmpdir,
        'explicit-save.dat',
    );
    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$explicit_save_path"] },
        '/save',
        '/exit',
    );
    is($status, 0, 'explicit save and exit alias succeed') or diag $err;
    like($out, qr/^Saved model to /m, '/save reports the destination');
    like($out, qr/^Bye\.$/m, '/exit uses normal quit behavior');
    ok(-s $explicit_save_path, '/save writes even a clean fresh model');
    is(
        TinyLLM->new(path => $explicit_save_path)->stats()->{total_tokens},
        0,
        'save and exit commands are not learned as text',
    );

    my $blocked_parent = File::Spec->catfile($tmpdir, 'blocked-parent');
    write_text($blocked_parent, "a file cannot also be a directory\n");
    my $unwritable_model = File::Spec->catfile($blocked_parent, 'model.dat');
    ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$unwritable_model"] },
        'remember this despite the save error',
        '/stats',
        '/quit',
    );
    isnt($status, 0, 'save failure makes the final status nonzero');
    my @save_errors = $err =~ /Failed to save model:/g;
    is(scalar @save_errors, 1, 'one mutation causes only one save attempt');
    like($out, qr/^Total tokens: [1-9][0-9]*$/m, 'session continues after save failure');
    like($out, qr/^Memories: 1$/m, 'unsaved in-memory knowledge remains usable');
    ok(!-e $unwritable_model, 'failed save creates no destination model');
};

subtest 'model path environment and explicit override are honored' => sub {
    my $environment_model = File::Spec->catfile($tmpdir, 'environment-model.dat');
    my ($out, $err, $status) = run_alita_session(
        { environment => { ALITA_LLM_PATH => $environment_model } },
        'hello from the environment path',
    );
    is($status, 0, 'environment-selected model session succeeds') or diag $err;
    ok(-s $environment_model, 'ALITA_LLM_PATH selects the model');

    my $unused_environment_model = File::Spec->catfile(
        $tmpdir,
        'unused-environment-model.dat',
    );
    my $argument_model = File::Spec->catfile($tmpdir, 'argument-model.dat');
    ($out, $err, $status) = run_alita_session(
        {
            environment => { ALITA_LLM_PATH => $unused_environment_model },
            arguments   => ["--model=$argument_model"],
        },
        'hello from the command-line path',
    );
    is($status, 0, 'explicit-model session succeeds') or diag $err;
    ok(-s $argument_model, '--model overrides ALITA_LLM_PATH');
    ok(!-e $unused_environment_model, 'overridden environment path is untouched');
};

subtest 'persisted model cap is retained and low-cap learning is atomic' => sub {
    my $capped_path = File::Spec->catfile($tmpdir, 'persisted-cap.dat');
    my $persisted_cap = 5_000;
    TinyLLM->new(
        path            => $capped_path,
        load            => 0,
        max_model_bytes => $persisted_cap,
    )->save();
    my $digest_before_stats = file_digest($capped_path);
    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$capped_path"] },
        '/stats',
        '/quit',
    );
    is($status, 0, 'saved-cap model opens without an explicit override') or diag $err;
    like(
        $out,
        qr/^Serialized bytes: \d+ \/ 5000$/m,
        'stats retain the smaller saved model cap',
    );
    is(file_digest($capped_path), $digest_before_stats, 'stats do not rewrite cap');

    my $low_cap_path = File::Spec->catfile($tmpdir, 'low-cap.dat');
    my $probe = TinyLLM->new(path => $low_cap_path, load => 0);
    my $low_cap = $probe->stats()->{serialized_bytes} + 64;
    my $long_message = join ' ', ('oversized-memory') x 200;
    ($out, $err, $status) = run_alita_session(
        {
            arguments => [
                "--model=$low_cap_path",
                "--max-model-bytes=$low_cap",
            ],
        },
        $long_message,
        '/stats',
        '/quit',
    );
    isnt($status, 0, 'learning beyond a configured model cap is an error');
    like($err, qr/Model size limit exceeded/, 'low-cap error is clear');
    like($out, qr/^Total tokens: 0$/m, 'failed learning rolls token counts back');
    like($out, qr/^Memories: 0$/m, 'failed learning rolls memories back');
    ok(!-e $low_cap_path, 'failed low-cap learning does not save a model');
};

subtest 'corrupt model load fails without overwriting the file' => sub {
    my $corrupt_path = File::Spec->catfile($tmpdir, 'corrupt-chat.dat');
    write_text($corrupt_path, "not a model\n");
    my $digest_before = file_digest($corrupt_path);
    my ($out, $err, $status) = run_alita_session(
        { arguments => ["--model=$corrupt_path"] },
        '/quit',
    );
    isnt($status, 0, 'corrupt model prevents startup');
    like($err, qr/Unable to start Alita: .*Failed to load model/s, 'load error is clear');
    is(file_digest($corrupt_path), $digest_before, 'corrupt model is not overwritten');
};

done_testing();

sub write_text {
    my ($path, $content) = @_;
    open my $file, '>:encoding(UTF-8)', $path
        or die "Failed to write $path: $!";
    print {$file} $content;
    close $file or die "Failed to close $path: $!";
}

sub file_digest {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "Failed to read $path: $!";
    my $digest = Digest::SHA->new(256)->addfile($file)->hexdigest;
    close $file or die "Failed to close $path: $!";
    return $digest;
}
