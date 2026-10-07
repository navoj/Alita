#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/lib";

use Getopt::Long qw(GetOptionsFromArray Configure);
use Alita::Agent;
use TinyLLM;

use constant HARD_MAX_BYTES     => 4_000_000_000;
use constant DEFAULT_FILE_BYTES => 10 * 1024 * 1024;

exit main();

sub main {
    my $encoding_ready = binmode(STDIN,  ':encoding(UTF-8)')
        && binmode(STDOUT, ':encoding(UTF-8)')
        && binmode(STDERR, ':encoding(UTF-8)');
    if (!$encoding_ready) {
        print STDERR "Could not configure UTF-8 terminal input and output: $!\n";
        return 1;
    }

    my @arguments = @ARGV;
    my %options = (
        model => exists($ENV{ALITA_LLM_PATH})
            ? $ENV{ALITA_LLM_PATH}
            : 'myBrainLLM.dat',
        max_model_bytes => undef,
        max_file_bytes  => DEFAULT_FILE_BYTES,
        help            => 0,
    );

    Configure(qw(no_auto_abbrev no_ignore_case));
    my $parsed = GetOptionsFromArray(
        \@arguments,
        'model=s'           => \$options{model},
        'max-model-bytes=s' => \$options{max_model_bytes},
        'max-file-bytes=s'  => \$options{max_file_bytes},
        'help|h'            => \$options{help},
    );
    if (!$parsed) {
        print STDERR "Use --help for usage.\n";
        return 2;
    }
    if (@arguments) {
        print STDERR "Unexpected argument: $arguments[0]\n";
        print STDERR "Use --help for usage.\n";
        return 2;
    }
    if ($options{help}) {
        print usage_text();
        return 0;
    }

    if (!defined($options{model}) || $options{model} eq '') {
        print STDERR "--model must name a model file\n";
        return 2;
    }
    for my $spec (
        ['--max-model-bytes', $options{max_model_bytes}],
        ['--max-file-bytes',  $options{max_file_bytes}],
    ) {
        my ($name, $value) = @{$spec};
        next if $name eq '--max-model-bytes' && !defined $value;
        if (!defined($value) || $value !~ /\A[1-9][0-9]*\z/
            || $value > HARD_MAX_BYTES) {
            print STDERR "$name must be an integer from 1 through "
                . HARD_MAX_BYTES . " bytes\n";
            return 2;
        }
    }

    my ($model, $agent);
    my $load_succeeded = eval {
        my %model_options = (path => $options{model});
        $model_options{max_model_bytes} = 0 + $options{max_model_bytes}
            if defined $options{max_model_bytes};
        $model = TinyLLM->new(%model_options);
        $agent = Alita::Agent->new(
            model          => $model,
            max_file_bytes => 0 + $options{max_file_bytes},
        );
        1;
    };
    if (!$load_succeeded) {
        print STDERR 'Unable to start Alita: ' . clean_error($@) . "\n";
        return 1;
    }

    select(STDOUT);
    $| = 1;
    my $interactive = -t STDIN && -t STDOUT;
    my $exit_status = 0;
    my $dirty = 0;
    my $generation = 0;
    my $last_save_attempt = -1;
    my $terminating = 0;

    my $persist;
    $persist = sub {
        my (%args) = @_;
        my $force = $args{force} // 0;
        return 1 if !$force && !$dirty;
        return 0 if !$force && $last_save_attempt == $generation;

        $last_save_attempt = $generation;
        my $saved = eval { $model->save(); 1 };
        if (!$saved) {
            print STDERR 'Failed to save model: ' . clean_error($@) . "\n";
            $exit_status = 1;
            return 0;
        }
        $dirty = 0;
        return 1;
    };

    my $mark_changed = sub {
        $generation++;
        $dirty = 1;
    };

    my $finish_for_signal = sub {
        return if $terminating;
        $terminating = 1;
        my $needed_save = $dirty;
        my $saved = $needed_save ? $persist->() : 1;
        if ($interactive) {
            print $needed_save && $saved
                ? "\nSaved model. Bye.\n"
                : "\nBye.\n";
        }
        exit $exit_status;
    };
    local $SIG{INT}  = sub { $finish_for_signal->() };
    local $SIG{TERM} = sub { $finish_for_signal->() };

    if ($interactive) {
        print "Alita TinyLLM chat\n";
        print "Type /help for commands.\n";
    }

    LINE:
    while (1) {
        print 'You: ' if $interactive;
        my $line = <STDIN>;
        last if !defined $line;
        $line =~ s/\r?\n\z//;
        next LINE if $line !~ /\S/;

        if ($line =~ m{\A/}) {
            my ($command, $argument) = $line =~ m{\A/([^\s]+)(?:\s+(.*))?\z}s;
            if (!defined $command) {
                print STDERR "Invalid command. Type /help for commands.\n";
                $exit_status = 1;
                next LINE;
            }
            $command = lc $command;
            $argument = '' if !defined $argument;

            if ($command eq 'help') {
                if ($argument ne '') {
                    command_argument_error('/help', \$exit_status);
                    next LINE;
                }
                print command_help();
                next LINE;
            }
            if ($command eq 'quit' || $command eq 'exit') {
                if ($argument ne '') {
                    command_argument_error("/$command", \$exit_status);
                    next LINE;
                }
                $persist->() if $dirty;
                print "Bye.\n";
                last LINE;
            }
            if ($command eq 'save') {
                if ($argument ne '') {
                    command_argument_error('/save', \$exit_status);
                    next LINE;
                }
                if ($persist->(force => 1)) {
                    print "Saved model to $options{model}\n";
                }
                next LINE;
            }
            if ($command eq 'stats') {
                if ($argument ne '') {
                    command_argument_error('/stats', \$exit_status);
                    next LINE;
                }
                print format_stats($model->stats());
                next LINE;
            }
            if ($command eq 'sources') {
                if ($argument ne '') {
                    command_argument_error('/sources', \$exit_status);
                    next LINE;
                }
                my $sources = eval { $agent->sources() };
                if ($@) {
                    print STDERR 'Could not list sources: ' . clean_error($@) . "\n";
                    $exit_status = 1;
                    next LINE;
                }
                print format_sources($sources);
                next LINE;
            }
            if ($command eq 'read') {
                my ($path, $path_error) = parse_read_path($argument);
                if (defined $path_error) {
                    print STDERR "$path_error\n";
                    $exit_status = 1;
                    next LINE;
                }
                my $summary = eval { $agent->ingest_file($path) };
                if ($@) {
                    print STDERR 'Could not read file: ' . clean_error($@) . "\n";
                    $exit_status = 1;
                    next LINE;
                }
                if ($summary->{changed}) {
                    $mark_changed->();
                    $persist->();
                }
                print format_import_summary($summary);
                next LINE;
            }
            if ($command eq 'teach') {
                my ($prompt, $response) = parse_teaching($argument);
                if (!defined $prompt) {
                    print STDERR "Usage: /teach question => answer\n";
                    $exit_status = 1;
                    next LINE;
                }
                my $acknowledgement = eval {
                    $agent->teach(prompt => $prompt, response => $response);
                };
                if ($@) {
                    print STDERR 'Could not teach response: ' . clean_error($@) . "\n";
                    $exit_status = 1;
                    next LINE;
                }
                $mark_changed->();
                $persist->();
                print "$acknowledgement\n";
                next LINE;
            }

            print STDERR "Unknown command '/$command'. Type /help for commands.\n";
            $exit_status = 1;
            next LINE;
        }

        my $reply = eval { $agent->chat($line) };
        if ($@) {
            print STDERR 'Could not learn from message: ' . clean_error($@) . "\n";
            $exit_status = 1;
            next LINE;
        }
        $mark_changed->();
        $persist->();
        $reply = '...' if !defined($reply) || $reply eq '';
        print $interactive ? "Alita: $reply\n" : "$reply\n";
    }

    $persist->() if $dirty;
    return $exit_status;
}

sub parse_read_path {
    my ($argument) = @_;
    $argument //= '';
    $argument =~ s/\A\s+//;
    $argument =~ s/\s+\z//;
    return (undef, 'Usage: /read PATH') if $argument eq '';

    if ($argument =~ /\A(["'])(.*)\1\z/s) {
        my $path = $2;
        return (undef, 'The /read path cannot be empty') if $path eq '';
        return ($path, undef);
    }
    return (undef, 'Malformed quoted path for /read')
        if $argument =~ /\A["']/ || $argument =~ /["']\z/;
    return ($argument, undef);
}

sub parse_teaching {
    my ($argument) = @_;
    return if !defined $argument;
    return if $argument !~ /\A\s*(.*?)\s*=>\s*(.*?)\s*\z/s;
    my ($prompt, $response) = ($1, $2);
    return if $prompt eq '' || $response eq '';
    return ($prompt, $response);
}

sub format_import_summary {
    my ($summary) = @_;
    my $verb = $summary->{duplicate} ? 'Already imported' : 'Imported';
    return sprintf "%s: %s (%d bytes, %d chunks, sha256 %s)\n",
        $verb,
        $summary->{source},
        $summary->{bytes},
        $summary->{chunks},
        $summary->{digest};
}

sub format_sources {
    my ($sources) = @_;
    return "No imported sources.\n" if !@{$sources};
    return join '', map {
        sprintf "Source: %s (chunks=%d, sha256=%s)\n",
            $_->{source}, $_->{chunks}, $_->{digest}
    } @{$sources};
}

sub format_stats {
    my ($stats) = @_;
    my $text = '';
    $text .= "Version: $stats->{version}\n";
    $text .= "Model: $stats->{path}\n";
    $text .= "Total tokens: $stats->{total_tokens}\n";
    $text .= "Vocabulary size: $stats->{vocabulary_size}\n";
    $text .= "Unique bigrams: $stats->{bigram_count}\n";
    $text .= "Memories: $stats->{memory_count}\n"
        if exists $stats->{memory_count};
    $text .= "Knowledge sources: $stats->{knowledge_sources}\n"
        if exists $stats->{knowledge_sources};
    $text .= "Serialized bytes: $stats->{serialized_bytes}";
    $text .= " / $stats->{max_model_bytes}"
        if exists $stats->{max_model_bytes};
    $text .= "\n";
    if ($stats->{classifier}) {
        $text .= "Classifier: $stats->{classifier}{algorithm}\n";
        $text .= "Classifier examples: $stats->{classifier}{total_examples}\n";
    } else {
        $text .= "Classifier: none\n";
    }
    return $text;
}

sub command_argument_error {
    my ($command, $exit_status) = @_;
    print STDERR "$command does not accept arguments\n";
    ${$exit_status} = 1;
}

sub clean_error {
    my ($error) = @_;
    $error = 'Unknown error' if !defined($error) || $error eq '';
    $error =~ s/\s+\z//;
    return $error;
}

sub usage_text {
    return <<'USAGE';
Use Alita as a persistent local TinyLLM chat.

Usage:
  perl alitaLLM.pl [options]

Options:
  --model=PATH              Model file (default: ALITA_LLM_PATH or myBrainLLM.dat)
  --max-model-bytes=N       Model budget (new default: 4000000000; saved cap retained)
  --max-file-bytes=N        /read file limit in bytes (default: 10485760)
  --help, -h                Show this help

Chat commands:
  /help                     Show chat commands
  /read PATH                Learn from a text file; quote paths containing spaces
  /teach question => answer Save an exact taught response
  /sources                  List imported files
  /stats                    Show model statistics
  /save                     Save the model now
  /quit, /exit              Save pending changes and leave
USAGE
}

sub command_help {
    return <<'HELP';
Commands:
  /help
  /read PATH
  /teach question => answer
  /sources
  /stats
  /save
  /quit (or /exit)
HELP
}
