package TinyLLM;
use strict;
use warnings;
use Storable qw(nstore_fd nfreeze retrieve dclone);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use POSIX qw(isfinite);
use Scalar::Util qw(looks_like_number reftype);
use Errno qw(EACCES EBUSY EPERM);
use Time::HiRes qw(sleep);

our $VERSION = '0.4';
our $MAX_MODEL_BYTES = 4_000_000_000;
our $MAX_CONVERSATION_MEMORIES = 200;

sub new {
    my ($class, %args) = @_;
    my $path = $args{path} // 'myBrainLLM.dat';
    my $load = exists $args{load} ? $args{load} : 1;
    my $limit = exists($args{max_model_bytes})
        ? $args{max_model_bytes} : $MAX_MODEL_BYTES;
    _validate_size_limit($limit);

    my $self = {
        path         => $path,
        unigrams     => {},
        bigrams      => {},
        total_tokens => 0,
        version      => $VERSION,
        max_model_bytes => 0 + $limit,
        memories     => [],
    };

    if ($load && -e $path) {
        die "Model '$path' is not a regular file\n" if !-f $path;
        my $file_bytes = -s $path;
        die "Model size limit exceeded before load: '$path' is $file_bytes bytes; limit is $limit bytes\n"
            if $file_bytes > $limit;
        my $loaded = eval { retrieve($path) };
        my $load_error = $@;
        die "Failed to load model '$path': $load_error"
            if $load_error;
        die "Invalid TinyLLM model '$path': expected a stored hash object\n"
            if !defined($loaded) || (reftype($loaded) // '') ne 'HASH';
        die "Invalid TinyLLM model '$path': missing unigram counts\n"
            if ref($loaded->{unigrams}) ne 'HASH';
        die "Invalid TinyLLM model '$path': missing bigram counts\n"
            if ref($loaded->{bigrams}) ne 'HASH';

        # Merge defaults first so permissive v0.1 plain hashes that contain
        # only unigram/bigram data still load with the newer schema.
        my $migrated = { %{$self}, %{$loaded} };
        if (!exists $loaded->{total_tokens}) {
            # Plain v0.1 hashes may omit the total. Reconstruct it from the
            # token counts rather than reporting zero training history.
            my $total = 0;
            for my $count (values %{$loaded->{unigrams}}) {
                die "Invalid TinyLLM model '$path': invalid unigram count\n"
                    if !defined($count) || ref($count)
                    || $count !~ /\A(?:0|[1-9][0-9]*)\z/;
                $total += $count;
            }
            $migrated->{total_tokens} = $total;
        }
        _validate_loaded_model($migrated, $path);

        # Accept either a plain HASH or a blessed TinyLLM object; merge keys.
        $self = $migrated;
    }

    # The caller's path always wins over a path stored inside the model file.
    $self->{path} = $path;
    $self->{version} = $VERSION;
    $self->{max_model_bytes} = 0 + $limit if exists $args{max_model_bytes};
    $self->{memories} = _prune_conversation_memories($self->{memories});
    delete $self->{_classifier_cache};

    bless $self, $class;
    $self->_assert_model_size();
    return $self;
}

sub _validate_size_limit {
    my ($limit) = @_;
    die "max_model_bytes must be an integer between 1 and $MAX_MODEL_BYTES (4 GB)\n"
        if !defined($limit) || ref($limit) || $limit !~ /\A[1-9][0-9]*\z/
        || $limit > $MAX_MODEL_BYTES;
}

sub _validate_memory {
    my ($memory) = @_;
    die "memory must be a hash with kind and text\n" if ref($memory) ne 'HASH';
    my %allowed = map { $_ => 1 } qw(kind text prompt source digest);
    die "unknown memory field '$_'\n" for grep { !$allowed{$_} } keys %{$memory};
    die "memory kind must be conversation, teaching, or file\n"
        if !defined($memory->{kind}) || ref($memory->{kind})
        || $memory->{kind} !~ /\A(?:conversation|teaching|file)\z/;
    die "memory text must be a string\n"
        if !defined($memory->{text}) || ref($memory->{text});
    for my $key (qw(prompt source digest)) {
        die "memory $key must be a string\n"
            if exists($memory->{$key}) && (!defined($memory->{$key}) || ref($memory->{$key}));
    }
    die "teaching memory requires a nonempty prompt\n"
        if $memory->{kind} eq 'teaching' && !length($memory->{prompt} // '');
    if ($memory->{kind} eq 'file') {
        die "file memory requires a source path and SHA-256 digest\n"
            if !length($memory->{source} // '')
            || ($memory->{digest} // '') !~ /\A[0-9a-f]{64}\z/i;
    }
}

sub _prune_conversation_memories {
    my ($memories) = @_;
    my $count = grep { $_->{kind} eq 'conversation' } @{$memories};
    my $discard = $count - $MAX_CONVERSATION_MEMORIES;
    return [@{$memories}] if $discard <= 0;
    return [grep {
        !($_->{kind} eq 'conversation' && $discard-- > 0)
    } @{$memories}];
}

sub _validate_loaded_model {
    my ($loaded, $path) = @_;
    my $invalid = sub {
        my ($detail) = @_;
        die "Invalid TinyLLM model '$path': $detail\n";
    };

    $invalid->('expected a stored hash object')
        if !defined($loaded) || (reftype($loaded) // '') ne 'HASH';
    $invalid->('missing unigram counts')
        if ref($loaded->{unigrams}) ne 'HASH';
    $invalid->('missing bigram counts')
        if ref($loaded->{bigrams}) ne 'HASH';
    $invalid->('invalid total token count')
        if !defined($loaded->{total_tokens})
        || !looks_like_number($loaded->{total_tokens})
        || !isfinite(0 + $loaded->{total_tokens})
        || $loaded->{total_tokens} < 0;
    my $metadata_valid = eval {
        _validate_size_limit($loaded->{max_model_bytes});
        die "memories must be an array\n" if ref($loaded->{memories}) ne 'ARRAY';
        _validate_memory($_) for @{$loaded->{memories}};
        1;
    };
    $invalid->($@ || 'invalid memory metadata') if !$metadata_valid;

    for my $token (keys %{$loaded->{unigrams}}) {
        my $count = $loaded->{unigrams}{$token};
        $invalid->("invalid unigram count for token '$token'")
            if !defined($count) || $count !~ /\A(?:0|[1-9][0-9]*)\z/;
    }
    for my $previous (keys %{$loaded->{bigrams}}) {
        my $row = $loaded->{bigrams}{$previous};
        $invalid->("invalid bigram row for token '$previous'")
            if ref($row) ne 'HASH';
        for my $next (keys %{$row}) {
            my $count = $row->{$next};
            $invalid->("invalid bigram count for '$previous' -> '$next'")
                if !defined($count) || $count !~ /\A(?:0|[1-9][0-9]*)\z/;
        }
    }

    my $classifier = $loaded->{classifier};
    return if !defined $classifier;
    $invalid->('classifier is not a hash')
        if ref($classifier) ne 'HASH';
    $invalid->('invalid classifier feature count')
        if !defined($classifier->{feature_count})
        || $classifier->{feature_count} !~ /\A[1-9][0-9]*\z/;
    $invalid->('invalid classifier threshold')
        if !defined($classifier->{threshold})
        || !looks_like_number($classifier->{threshold})
        || !isfinite(0 + $classifier->{threshold});
    $invalid->('invalid classifier example count')
        if !defined($classifier->{total_examples})
        || $classifier->{total_examples} !~ /\A(?:0|[1-9][0-9]*)\z/;
    $invalid->('classifier labels are not a hash')
        if ref($classifier->{labels}) ne 'HASH';

    my $example_sum = 0;
    for my $label (keys %{$classifier->{labels}}) {
        my $data = $classifier->{labels}{$label};
        $invalid->("invalid data for label '$label'")
            if ref($data) ne 'HASH';
        $invalid->("invalid example count for label '$label'")
            if !defined($data->{examples})
            || $data->{examples} !~ /\A(?:0|[1-9][0-9]*)\z/;
        $invalid->("invalid feature counts for label '$label'")
            if ref($data->{active_counts}) ne 'ARRAY'
            || @{$data->{active_counts}} != $classifier->{feature_count};

        for my $count (@{$data->{active_counts}}) {
            $invalid->("invalid active count for label '$label'")
                if !defined($count) || $count !~ /\A(?:0|[1-9][0-9]*)\z/
                || $count > $data->{examples};
        }
        $example_sum += $data->{examples};
    }
    $invalid->('classifier label counts do not match its total')
        if $example_sum != $classifier->{total_examples};
}

sub save {
    my ($self) = @_;
    my $path = $self->{path};
    $self->_assert_model_size();

    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    my $dirpath = File::Spec->catpath($vol, $dir, '');
    if ($dirpath && !-d $dirpath) {
        make_path($dirpath);
    }

    my ($output, $tmp) = tempfile(
        'tinyllm-model-XXXXXX',
        DIR => $dirpath || '.',
        UNLINK => 0,
    );
    my $saved = eval {
        binmode $output or die "Failed to set binary mode for $tmp: $!";
        nstore_fd($self->_snapshot(), $output)
            or die "Failed to write $tmp: $!";
        close $output or die "Failed to close $tmp: $!";
        my $actual_bytes = -s $tmp;
        die "Model size limit exceeded before save: $actual_bytes bytes; limit is $self->{max_model_bytes} bytes\n"
            if $actual_bytes > $self->{max_model_bytes};
        $self->_replace_model_file($tmp, $path);
        1;
    };
    if (!$saved) {
        my $error = $@ || "Failed to save model '$path'\n";
        close $output if defined fileno($output);
        unlink $tmp if -e $tmp;
        die $error;
    }
    return $self;
}

sub _replace_model_file {
    my ($self, $temporary, $destination) = @_;
    # Windows synchronization/indexing software can hold a just-written model
    # briefly. Retry only the atomic rename, never unlink the good destination.
    for my $attempt (1 .. 20) {
        return 1 if rename $temporary, $destination;
        my $error = "$!";
        my $error_number = 0 + $!;
        my $retryable = $^O eq 'MSWin32' && -f $destination
            && ($error_number == EACCES || $error_number == EBUSY || $error_number == EPERM);
        die "Failed to move $temporary to $destination: $error\n"
            if !$retryable || $attempt == 20;
        sleep(0.1);
    }
}

sub _snapshot {
    my ($self) = @_;
    # Cached prediction parameters can be rebuilt from the stored counts.
    my %snapshot = %{$self};
    delete $snapshot{_classifier_cache};
    return bless \%snapshot, ref($self);
}

sub stats {
    my ($self) = @_;
    my $bigram_count = 0;
    $bigram_count += scalar keys %{$_} for values %{$self->{bigrams}};
    my $vocabulary_size = scalar grep {
        $_ ne '<BOS>' && $_ ne '<EOS>'
    } keys %{$self->{unigrams}};
    my %sources = map { $_->{source} => 1 }
        grep { $_->{kind} eq 'file' } @{$self->{memories}};

    return {
        version         => $VERSION,
        path            => $self->{path},
        total_tokens    => $self->{total_tokens},
        vocabulary_size => $vocabulary_size,
        bigram_count    => $bigram_count,
        # Storable's file representation adds the four-byte 'pst0' signature
        # to the network-order serialization returned by nfreeze.
        serialized_bytes => $self->_serialized_bytes(),
        max_model_bytes  => $self->{max_model_bytes},
        memory_count     => scalar @{$self->{memories}},
        knowledge_sources => scalar keys %sources,
        classifier       => $self->classifier_stats(),
    };
}

sub _serialized_bytes {
    my ($self) = @_;
    return length(nfreeze($self->_snapshot())) + length('pst0');
}

sub _assert_model_size {
    my ($self) = @_;
    _validate_size_limit($self->{max_model_bytes});
    my $bytes = $self->_serialized_bytes();
    die "Model size limit exceeded: $bytes bytes; limit is $self->{max_model_bytes} bytes. Existing knowledge preserved.\n"
        if $bytes > $self->{max_model_bytes};
    return $bytes;
}

sub memories {
    my ($self) = @_;
    return dclone($self->{memories});
}

sub _tokenize {
    my ($text) = @_;
    $text //= '';
    # Normalize whitespace and lowercase; keep alphanumerics and apostrophes as tokens
    my @words = map { lc $_ } ($text =~ m/([A-Za-z0-9']+)/g);
    return @words;
}

sub train {
    my ($self, $text) = @_;
    return $self->learn(texts => [$text // '']);
}

# Apply a whole chat turn or file import atomically. Only changed count cells
# are journaled, avoiding a second copy of the complete model for rollback.
sub learn {
    my ($self, %args) = @_;
    die "unknown learn argument '$_'\n"
        for grep { $_ ne 'texts' && $_ ne 'memories' } keys %args;
    my $texts = $args{texts} // [];
    my $memories = $args{memories} // [];
    die "texts must be an array of strings\n" if ref($texts) ne 'ARRAY';
    die "memories must be an array of memory hashes\n" if ref($memories) ne 'ARRAY';
    die "texts must be an array of strings\n"
        for grep { !defined($_) || ref($_) } @{$texts};
    _validate_memory($_) for @{$memories};

    my (%unigram_delta, %bigram_delta);
    my $token_delta = 0;
    for my $text (@{$texts}) {
        my @tokens = ('<BOS>', _tokenize($text), '<EOS>');
        $token_delta += @tokens;
        for my $i (0 .. $#tokens) {
            $unigram_delta{$tokens[$i]}++;
            $bigram_delta{$tokens[$i-1]}{$tokens[$i]}++ if $i;
        }
    }
    my $old_memories = $self->{memories};
    my $next_memories = _prune_conversation_memories([
        @{$old_memories}, map { { %{$_} } } @{$memories},
    ]);

    my (%old_unigrams, %old_bigrams, %old_rows);
    for my $token (keys %unigram_delta) {
        $old_unigrams{$token} = $self->{unigrams}{$token};
        $self->{unigrams}{$token} += $unigram_delta{$token};
    }
    for my $previous (keys %bigram_delta) {
        $old_rows{$previous} = exists $self->{bigrams}{$previous};
        $self->{bigrams}{$previous} ||= {};
        for my $next (keys %{$bigram_delta{$previous}}) {
            $old_bigrams{$previous}{$next} = $self->{bigrams}{$previous}{$next};
            $self->{bigrams}{$previous}{$next} += $bigram_delta{$previous}{$next};
        }
    }
    my $old_total = $self->{total_tokens};
    $self->{total_tokens} += $token_delta;
    $self->{memories} = $next_memories;
    my $accepted = eval { $self->_assert_model_size(); 1 };
    if (!$accepted) {
        my $error = $@;
        for my $token (keys %old_unigrams) {
            if (defined $old_unigrams{$token}) {
                $self->{unigrams}{$token} = $old_unigrams{$token};
            } else {
                delete $self->{unigrams}{$token};
            }
        }
        for my $previous (keys %old_bigrams) {
            if (!$old_rows{$previous}) {
                delete $self->{bigrams}{$previous};
                next;
            }
            for my $next (keys %{$old_bigrams{$previous}}) {
                if (defined $old_bigrams{$previous}{$next}) {
                    $self->{bigrams}{$previous}{$next} = $old_bigrams{$previous}{$next};
                } else {
                    delete $self->{bigrams}{$previous}{$next};
                }
            }
        }
        $self->{total_tokens} = $old_total;
        $self->{memories} = $old_memories;
        die $error;
    }
    return $self;
}

sub _next_dist {
    my ($self, $prev) = @_;
    $prev //= '<BOS>';
    my $row = $self->{bigrams}{$prev} || {};
    my %dist = %$row;
    # Add-one smoothing over observed next tokens and <EOS> as a fallback
    $dist{'<EOS>'} ||= 0;
    my $sum = 0;
    for my $k (keys %dist) {
        $dist{$k} = $dist{$k} + 1;
        $sum += $dist{$k};
    }
    return {} unless $sum > 0;
    $_ /= $sum for values %dist;
    return \%dist;
}

sub _sample {
    my ($dist, $temperature) = @_;
    $temperature = 1.0 if !defined $temperature || $temperature <= 0;

    # Subtract the largest log probability before applying temperature.
    # This retains a nonzero maximum weight even for tiny temperatures.
    my $largest_log;
    for my $p (values %{$dist}) {
        my $log_p = log($p);
        $largest_log = $log_p if !defined($largest_log) || $log_p > $largest_log;
    }
    my %adj;
    my $sum = 0.0;
    for my $k (keys %$dist) {
        my $q = exp((log($dist->{$k}) - $largest_log) / $temperature);
        $adj{$k} = $q;
        $sum += $q;
    }
    return undef if $sum <= 0;

    $_ /= $sum for values %adj;

    my $r = rand();
    my $acc = 0.0;
    for my $k (sort keys %adj) {
        $acc += $adj{$k};
        if ($r <= $acc) {
            return $k;
        }
    }
    # Fallback (shouldn't happen due to floating point)
    my @keys = keys %adj;
    return $keys[int(rand(@keys))];
}

sub reply {
    my ($self, %args) = @_;
    my $prompt      = $args{prompt} // '';
    my $max_tokens  = $args{max_tokens} // 50;
    my $temperature = $args{temperature} // 0.9;

    die "max_tokens must be a nonnegative integer\n"
        if ref($max_tokens) || $max_tokens !~ /\A(?:0|[1-9][0-9]*)\z/;
    die "temperature must be a finite number\n"
        if !looks_like_number($temperature) || !isfinite(0 + $temperature);

    my @ctx = _tokenize($prompt);
    my $prev = @ctx ? $ctx[-1] : '<BOS>';

    my @out;
    for (1..$max_tokens) {
        my $dist = $self->_next_dist($prev);
        last unless $dist && %$dist;
        my $tok = _sample($dist, $temperature);
        last if !defined $tok || $tok eq '<EOS>';
        push @out, $tok;
        $prev = $tok;
    }
    my $text = join(' ', @out);
    $text =~ s/\s+([.,!?;:])/$1/g; # light de-spacing before punctuation
    return $text;
}

sub train_example {
    my ($self, %args) = @_;
    my $old_classifier = $self->{classifier};
    my $old_cache = $self->{_classifier_cache};
    my $label = defined($args{label}) && !ref($args{label}) ? "$args{label}" : '';
    my $old_label = $old_classifier && exists($old_classifier->{labels}{$label})
        ? dclone($old_classifier->{labels}{$label}) : undef;
    my $old_total = $old_classifier ? $old_classifier->{total_examples} : 0;
    my $accepted = eval {
        $self->_train_example_unchecked(%args);
        $self->_assert_model_size();
        1;
    };
    if (!$accepted) {
        my $error = $@;
        if ($old_classifier) {
            $self->{classifier} = $old_classifier;
            $old_classifier->{total_examples} = $old_total;
            if ($old_label) {
                $old_classifier->{labels}{$label} = $old_label;
            } else {
                delete $old_classifier->{labels}{$label};
            }
        } else {
            delete $self->{classifier};
        }
        if ($old_cache) {
            $self->{_classifier_cache} = $old_cache;
        } else {
            delete $self->{_classifier_cache};
        }
        die $error;
    }
    return $self;
}

sub _train_example_unchecked {
    my ($self, %args) = @_;
    die "train_example requires a label\n"
        if !exists($args{label}) || !defined($args{label})
        || ref($args{label}) || $args{label} eq '';

    my $features = $args{features};
    die "train_example requires features as an array reference\n"
        if ref($features) ne 'ARRAY';
    die "train_example requires at least one feature\n" if !@{$features};

    my $threshold = exists $args{threshold} ? $args{threshold}
        : $self->{classifier} ? $self->{classifier}{threshold} : 0.5;
    die "threshold must be a finite number\n"
        if !looks_like_number($threshold) || !isfinite(0 + $threshold);
    $threshold = 0 + $threshold;

    # Validate the whole vector before changing counts so a malformed example
    # cannot leave a partially updated in-memory classifier.
    for my $i (0 .. $#{$features}) {
        my $value = $features->[$i];
        die "feature $i is not a finite number\n"
            if !defined($value) || !looks_like_number($value)
            || !isfinite(0 + $value);
    }

    my $classifier = $self->{classifier};
    if (!$classifier) {
        $classifier = $self->{classifier} = {
            feature_count  => scalar(@{$features}),
            threshold      => $threshold,
            total_examples => 0,
            labels         => {},
        };
    }

    die sprintf(
        "feature count mismatch: model expects %d but received %d\n",
        $classifier->{feature_count}, scalar(@{$features}),
    ) if @{$features} != $classifier->{feature_count};

    die sprintf(
        "threshold mismatch: model uses %s but received %s\n",
        $classifier->{threshold}, $threshold,
    ) if $threshold != $classifier->{threshold};

    my $label = "$args{label}";
    my $label_data = $classifier->{labels}{$label};
    if (!$label_data) {
        $label_data = $classifier->{labels}{$label} = {
            examples      => 0,
            active_counts => [(0) x $classifier->{feature_count}],
        };
    }

    for my $i (0 .. $#{$features}) {
        $label_data->{active_counts}[$i]++
            if $features->[$i] >= $threshold;
    }

    $label_data->{examples}++;
    $classifier->{total_examples}++;
    delete $self->{_classifier_cache};
    return $self;
}

sub _classifier_parameters {
    my ($self, $alpha) = @_;
    my $classifier = $self->{classifier};
    die "classifier has not been trained\n"
        if !$classifier || !$classifier->{total_examples};

    my $cache = $self->{_classifier_cache};
    if ($cache && $cache->{alpha} == $alpha) {
        return $cache->{parameters};
    }

    # Labels are opaque strings. Lexical ordering gives deterministic tie
    # breaking even for mixtures such as "1", "01", and "unknown".
    my @labels = sort keys %{$classifier->{labels}};

    my $label_count = scalar @labels;
    my @parameters;
    for my $label (@labels) {
        my $data = $classifier->{labels}{$label};
        my $examples = $data->{examples};
        my $base_score = _log_count_plus_alpha($examples, $alpha, 1)
            - _log_count_plus_alpha(
                $classifier->{total_examples},
                $alpha,
                $label_count,
            );
        my @active_delta;
        my $log_denominator = _log_count_plus_alpha($examples, $alpha, 2);

        for my $i (0 .. $classifier->{feature_count} - 1) {
            my $active = $data->{active_counts}[$i] // 0;
            my $log_active = _log_count_plus_alpha($active, $alpha, 1)
                - $log_denominator;
            my $log_inactive = _log_count_plus_alpha(
                $examples - $active,
                $alpha,
                1,
            ) - $log_denominator;
            $base_score += $log_inactive;
            $active_delta[$i] = $log_active - $log_inactive;
        }

        push @parameters, {
            label        => $label,
            base_score   => $base_score,
            active_delta => \@active_delta,
        };
    }

    $self->{_classifier_cache} = {
        alpha      => $alpha,
        parameters => \@parameters,
    };
    return \@parameters;
}

sub _log_count_plus_alpha {
    my ($count, $alpha, $alpha_multiplier) = @_;
    my $log_alpha_term = log($alpha) + log($alpha_multiplier);
    return $log_alpha_term if !$count;

    my $log_count = log($count);
    my ($high, $low) = $log_count >= $log_alpha_term
        ? ($log_count, $log_alpha_term)
        : ($log_alpha_term, $log_count);
    return $high + log(1 + exp($low - $high));
}

sub predict {
    my ($self, %args) = @_;
    my $features = $args{features};
    die "predict requires features as an array reference\n"
        if ref($features) ne 'ARRAY';

    my $classifier = $self->{classifier};
    die "classifier has not been trained\n"
        if !$classifier || !$classifier->{total_examples};
    die sprintf(
        "feature count mismatch: model expects %d but received %d\n",
        $classifier->{feature_count}, scalar(@{$features}),
    ) if @{$features} != $classifier->{feature_count};

    my $alpha = exists $args{alpha} ? $args{alpha} : 1;
    die "alpha must be a positive finite number\n"
        if !looks_like_number($alpha) || !isfinite(0 + $alpha) || $alpha <= 0;
    $alpha = 0 + $alpha;

    my @active_features;
    for my $i (0 .. $#{$features}) {
        my $value = $features->[$i];
        die "feature $i is not a finite number\n"
            if !defined($value) || !looks_like_number($value)
            || !isfinite(0 + $value);
        push @active_features, $i if $value >= $classifier->{threshold};
    }

    my $parameters = $self->_classifier_parameters($alpha);
    my %scores;
    my ($best_label, $best_score);
    for my $params (@{$parameters}) {
        my $score = $params->{base_score};
        $score += $params->{active_delta}[$_] for @active_features;
        $scores{$params->{label}} = $score;
        if (!defined($best_score) || $score > $best_score) {
            $best_label = $params->{label};
            $best_score = $score;
        }
    }

    # Convert log scores into normalized probabilities without underflow.
    my %probabilities;
    my $probability_sum = 0;
    for my $label (keys %scores) {
        my $probability = exp($scores{$label} - $best_score);
        $probabilities{$label} = $probability;
        $probability_sum += $probability;
    }
    $_ /= $probability_sum for values %probabilities;

    return {
        label         => $best_label,
        confidence    => $probabilities{$best_label},
        probabilities => \%probabilities,
    };
}

sub classifier_stats {
    my ($self) = @_;
    my $classifier = $self->{classifier};
    return undef if !$classifier;

    my %examples_by_label = map {
        $_ => $classifier->{labels}{$_}{examples}
    } keys %{$classifier->{labels}};

    return {
        algorithm         => 'bernoulli_naive_bayes',
        feature_count     => $classifier->{feature_count},
        label_count       => scalar(keys %examples_by_label),
        stored_feature_counts => $classifier->{feature_count} * scalar(keys %examples_by_label),
        threshold         => $classifier->{threshold},
        total_examples    => $classifier->{total_examples},
        examples_by_label => \%examples_by_label,
    };
}

1;

__END__

=pod

=head1 NAME

TinyLLM - Bounded incremental text, memory, and supervised classification

=head1 SYNOPSIS

  use lib 'lib';
  use TinyLLM;

  my $llm = TinyLLM->new(path => 'myBrainLLM.dat');
  $llm->train("Hello there, how are you?");
  $llm->save();

  my $reply = $llm->reply(prompt => "Hello", max_tokens => 40, temperature => 0.8);
  print "$reply\n";

  # Alita::Agent adds conversation and explicit local-file knowledge retrieval.
  use Alita::Agent;
  my $alita = Alita::Agent->new(model => $llm);
  $alita->teach(prompt => 'What is my name?', response => 'Your name is Jovan.');
  print $alita->chat('What is my name?'), "\n";
  $llm->save();

  # Supervised classification uses the same save/load mechanism.
  $llm->train_example(
      label     => 'one',
      features  => [0, 255, 255, 0],
      threshold => 128,
  );
  $llm->save();
  my $result = $llm->predict(features => [0, 240, 250, 0]);
  print "$result->{label}\n";

=head1 DESCRIPTION

A minimal bigram-based "tiny LLM" that can be incrementally trained from
conversational input and persisted to the configured model path
(C<myBrainLLM.dat> by default). This is not a neural transformer or a general
reasoning engine. It also contains a small Bernoulli naive Bayes
classifier for labeled numeric feature vectors. It provides:

=over 4

=item * C<new(path =E<gt> $file, load =E<gt> 0|1, max_model_bytes =E<gt> $bytes)> to create a model, loading an existing file unless C<load> is false. The persisted-state limit defaults to 4,000,000,000 bytes and cannot exceed that hard ceiling. Without an explicit override, a loaded model retains its saved smaller limit.

=item * C<train($text)> to update the model with new text.

=item * C<learn(texts =E<gt> \@texts, memories =E<gt> \@memories)> to atomically update token counts and memory. Each memory has C<kind> (conversation, teaching, or file) and C<text>; teaching requires C<prompt>, and file requires C<source> and a SHA-256 C<digest>. The newest 200 conversation memories are retained; teaching and file records are kept. Pruning memory does not remove cumulative token counts.

=item * C<memories()> to return an independent copy of the stored memory records.

=item * C<reply(prompt =E<gt> $text, max_tokens =E<gt> N, temperature =E<gt> T)> to generate a response.

=item * C<save()> to persist the text and classifier state using a unique temporary file, then replace the destination on success.

=item * C<train_example(label =E<gt> $label, features =E<gt> \@values, threshold =E<gt> $number)> to incrementally train the classifier. An omitted threshold inherits the existing classifier's threshold, or defaults to C<0.5> for a fresh classifier.

=item * C<predict(features =E<gt> \@values, alpha =E<gt> $number)> to return a hash reference containing the label, confidence, and probabilities. Alpha defaults to C<1>.

=item * C<classifier_stats()> to return classifier metadata, label example counts, and the number of stored feature counts without exposing the feature-count arrays.

=item * C<stats()> to return vocabulary size, unique bigram count, total trained tokens (including boundary tokens), serialized size in bytes, C<max_model_bytes>, C<memory_count>, C<knowledge_sources> (distinct file paths), and classifier metadata. Serialization excludes the prediction cache.

=back

Text, classifier, and memory updates reject changes that exceed the saved-state
budget and roll back their changes. Saving checks the actual temporary file
before replacing the destination. The ceiling is not a process RAM limit:
Perl hashes, prediction caches, and serialization buffers require additional
memory. Load only trusted Storable model files.

=cut
