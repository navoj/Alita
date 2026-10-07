package TinyLLM;
use strict;
use warnings;
use Storable qw(nstore_fd nfreeze retrieve);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use POSIX qw(isfinite);
use Scalar::Util qw(looks_like_number reftype);

our $VERSION = '0.3';

sub new {
    my ($class, %args) = @_;
    my $path = $args{path} // 'myBrainLLM.dat';
    my $load = exists $args{load} ? $args{load} : 1;

    my $self = {
        path         => $path,
        unigrams     => {},
        bigrams      => {},
        total_tokens => 0,
        version      => $VERSION,
    };

    if ($load && -e $path) {
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
    delete $self->{_classifier_cache};

    bless $self, $class;
    return $self;
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
        rename $tmp, $path or die "Failed to move $tmp to $path: $!";
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

    return {
        version         => $VERSION,
        path            => $self->{path},
        total_tokens    => $self->{total_tokens},
        vocabulary_size => $vocabulary_size,
        bigram_count    => $bigram_count,
        # Storable's file representation adds the four-byte 'pst0' signature
        # to the network-order serialization returned by nfreeze.
        serialized_bytes => length(nfreeze($self->_snapshot())) + length('pst0'),
        classifier       => $self->classifier_stats(),
    };
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
    my @tokens = ('<BOS>', _tokenize($text), '<EOS>');

    for my $i (0..$#tokens) {
        my $tok = $tokens[$i];
        $self->{unigrams}{$tok}++;
        $self->{total_tokens}++;
        if ($i > 0) {
            my $prev = $tokens[$i-1];
            $self->{bigrams}{$prev} ||= {};
            $self->{bigrams}{$prev}{$tok}++;
        }
    }
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

TinyLLM - A tiny bigram text generator and supervised vector classifier

=head1 SYNOPSIS

  use lib 'lib';
  use TinyLLM;

  my $llm = TinyLLM->new(path => 'myBrainLLM.dat');
  $llm->train("Hello there, how are you?");
  $llm->save();

  my $reply = $llm->reply(prompt => "Hello", max_tokens => 40, temperature => 0.8);
  print "$reply\n";

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
(C<myBrainLLM.dat> by default). It also contains a small Bernoulli naive Bayes
classifier for labeled numeric feature vectors. It provides:

=over 4

=item * C<new(path =E<gt> $file, load =E<gt> 0|1)> to create a model, loading an existing file unless C<load> is false.

=item * C<train($text)> to update the model with new text.

=item * C<reply(prompt =E<gt> $text, max_tokens =E<gt> N, temperature =E<gt> T)> to generate a response.

=item * C<save()> to persist the text and classifier state using a unique temporary file, then replace the destination on success.

=item * C<train_example(label =E<gt> $label, features =E<gt> \@values, threshold =E<gt> $number)> to incrementally train the classifier. An omitted threshold inherits the existing classifier's threshold, or defaults to C<0.5> for a fresh classifier.

=item * C<predict(features =E<gt> \@values, alpha =E<gt> $number)> to return a hash reference containing the label, confidence, and probabilities. Alpha defaults to C<1>.

=item * C<classifier_stats()> to return classifier metadata, label example counts, and the number of stored feature counts without exposing the feature-count arrays.

=item * C<stats()> to return vocabulary size, unique bigram count, total trained tokens (including boundary tokens), serialized size in bytes, and classifier metadata. Serialization excludes the prediction cache.

=back

=cut
