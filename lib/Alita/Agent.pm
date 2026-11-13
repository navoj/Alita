package Alita::Agent;

use strict;
use warnings;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode FB_CROAK);
use Scalar::Util qw(blessed);
use utf8 ();

our $VERSION = '0.1';

use constant DEFAULT_MAX_FILE_BYTES => 10_485_760;
use constant HARD_MAX_BYTES         => 4_000_000_000;
use constant FILE_CHUNK_CHARS       => 1_500;

my %STOPWORD = map { $_ => 1 } qw(
    a about again all am an and any are as at be because been before being
    but by can could did do does doing for from get got had has have he her
    here hers herself him himself his how i if in into is it its itself just
    me more most my myself no nor not of on once only or other our ours
    ourselves out over own same she should so some such than that the their
    theirs them themselves then there these they this those through to too
    under up us very was we were what when where which while who why will
    with would you your yours yourself yourselves please tell now
);

sub new {
    my ($class, %args) = @_;
    my $model = delete $args{model};
    my $max_file_bytes = exists $args{max_file_bytes}
        ? delete $args{max_file_bytes}
        : DEFAULT_MAX_FILE_BYTES;

    die "Unknown Alita::Agent option: " . (sort keys %args)[0] . "\n"
        if %args;
    die "model must be a TinyLLM-compatible object\n"
        if !blessed($model)
        || !$model->can('learn')
        || !$model->can('memories');
    die "max_file_bytes must be a positive integer no larger than "
        . HARD_MAX_BYTES . "\n"
        if !defined($max_file_bytes)
        || ref($max_file_bytes)
        || $max_file_bytes !~ /\A[1-9][0-9]*\z/
        || $max_file_bytes > HARD_MAX_BYTES;

    return bless {
        model          => $model,
        max_file_bytes => 0 + $max_file_bytes,
    }, $class;
}

sub chat {
    my ($self, $text) = @_;
    die "chat expects one text argument\n" if @_ != 2;
    $text = _required_text($text, 'chat text');

    # Retrieval deliberately happens before this turn is learned.  A new
    # utterance therefore cannot be returned as its own answer.
    my $memories = $self->{model}->memories();
    my $query = $text;
    my $is_greeting = _is_greeting($text);
    my $is_statement = _is_obvious_statement($text);
    my $is_followup = _is_followup($text);
    if ($is_followup) {
        my $previous = _latest_context_conversation($memories);
        $query = $previous->{prompt} // $previous->{text}
            if defined $previous;
    }

    # A greeting stays a greeting rather than matching an old "hello" turn.
    # An explicitly taught greeting still wins, as all exact teachings do.
    my $response = _exact_teaching($query, $memories);
    if (!defined($response) && $is_statement) {
        $response = q{Got it. I'll remember that.};
    }
    elsif (!defined($response) && !$is_greeting) {
        $response = _retrieve(
            query           => $query,
            memories        => $memories,
            no_conversation => $is_followup,
        );
    }
    if (!defined $response) {
        if ($is_greeting) {
            $response = 'Hello! I can remember what you tell me, learn exact '
                . 'answers with /teach, and read an explicit local UTF-8 text '
                . 'file with /read.';
        }
        else {
            $response = q{I don't have a matching memory yet. You can teach me }
                . 'with /teach or load an explicit local UTF-8 text file with '
                . '/read.';
        }
    }

    $self->{model}->learn(
        texts    => [$text],
        memories => [{
            kind   => 'conversation',
            prompt => $text,
            text   => $text,
        }],
    );

    return $response;
}

sub teach {
    my ($self, %args) = @_;
    my $prompt = delete $args{prompt};
    my $response = delete $args{response};
    die "Unknown teach option: " . (sort keys %args)[0] . "\n" if %args;

    $prompt = _required_text($prompt, 'teaching prompt');
    $response = _required_text($response, 'teaching response');

    $self->{model}->learn(
        texts    => [$prompt, $response],
        memories => [{
            kind   => 'teaching',
            prompt => $prompt,
            text   => $response,
        }],
    );

    return "Learned response for: $prompt";
}

sub ingest_file {
    my ($self, $path) = @_;
    die "ingest_file expects one path argument\n" if @_ != 2;
    $path = _required_text($path, 'file path');

    die "Only explicit local file paths can be read\n"
        if $path =~ m{\A(?:[A-Za-z][A-Za-z0-9+.-]*://|\\\\|//)};
    die "File '$path' is not a regular local file\n" if !-f $path;

    my $source = abs_path($path);
    die "Could not resolve local file '$path'\n" if !defined $source;
    die "Network file paths are not supported\n"
        if $source =~ m{\A(?:\\\\|//)};

    my $early_size = -s $path;
    die "Could not determine the size of '$source'\n"
        if !defined $early_size;
    die _too_large_message($source, $self->{max_file_bytes})
        if $early_size > $self->{max_file_bytes};

    open my $input, '<:raw', $path
        or die "Could not open '$source' for reading: $!\n";
    if (!-f $input) {
        close $input;
        die "File '$source' is not a regular local file\n";
    }

    my $bytes = '';
    my $byte_count = 0;
    my $read_ok = eval {
        while (1) {
            my $buffer = '';
            my $count = sysread($input, $buffer, 65_536);
            die "Could not read '$source': $!\n" if !defined $count;
            last if $count == 0;
            $byte_count += $count;
            die _too_large_message($source, $self->{max_file_bytes})
                if $byte_count > $self->{max_file_bytes};
            $bytes .= $buffer;
        }
        close $input or die "Could not close '$source': $!\n";
        1;
    };
    if (!$read_ok) {
        my $error = $@ || "Could not read '$source'\n";
        close $input if defined fileno($input);
        die $error;
    }

    my $digest = sha256_hex($bytes);
    my $text = eval { decode('UTF-8', $bytes, FB_CROAK) };
    die "File '$source' is not valid UTF-8 text: $@"
        if $@;
    $text =~ s/\A\x{FEFF}//;
    die "File '$source' appears to contain binary data\n"
        if $text =~ /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/;

    my $memories = $self->{model}->memories();
    for my $memory (@{$memories}) {
        next if ($memory->{kind} // '') ne 'file';
        next if !defined($memory->{source}) || !defined($memory->{digest});
        if (_same_path($memory->{source}, $source)
            && $memory->{digest} eq $digest) {
            my $chunks = _source_chunk_count($memories, $source, $digest);
            return {
                source    => $source,
                digest    => $digest,
                bytes     => $byte_count,
                chunks    => $chunks,
                duplicate => 1,
                changed   => 0,
            };
        }
    }

    my @chunks = _chunk_text($text, FILE_CHUNK_CHARS);
    die "File '$source' contains no readable text\n" if !@chunks;

    my @file_memories = map {
        +{
            kind   => 'file',
            text   => $_,
            source => $source,
            digest => $digest,
        }
    } @chunks;

    # TinyLLM::learn provides the transaction boundary: either every chunk
    # and memory is accepted within the model cap, or nothing is changed.
    $self->{model}->learn(
        texts    => \@chunks,
        memories => \@file_memories,
    );

    return {
        source    => $source,
        digest    => $digest,
        bytes     => $byte_count,
        chunks    => scalar @chunks,
        duplicate => 0,
        changed   => 1,
    };
}

sub sources {
    my ($self) = @_;
    die "sources does not accept arguments\n" if @_ != 1;

    my %sources;
    for my $memory (@{$self->{model}->memories()}) {
        next if ($memory->{kind} // '') ne 'file';
        next if !defined($memory->{source}) || !defined($memory->{digest});
        my $key = $memory->{source} . "\0" . $memory->{digest};
        $sources{$key} ||= {
            source => $memory->{source},
            digest => $memory->{digest},
            chunks => 0,
        };
        $sources{$key}{chunks}++;
    }

    return [
        sort {
            lc($a->{source}) cmp lc($b->{source})
                || $a->{source} cmp $b->{source}
                || $a->{digest} cmp $b->{digest}
        } values %sources
    ];
}

sub _required_text {
    my ($value, $name) = @_;
    die "$name must be a defined, non-reference string\n"
        if !defined($value) || ref($value);
    die "$name is not a valid string\n" if !utf8::valid($value);
    $value =~ s/\A\s+//;
    $value =~ s/\s+\z//;
    die "$name must not be empty\n" if $value eq '';
    die "$name contains unsupported control characters\n"
        if $value =~ /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/;
    return $value;
}

sub _too_large_message {
    my ($source, $limit) = @_;
    return "File '$source' exceeds the $limit-byte limit\n";
}

sub _same_path {
    my ($left, $right) = @_;
    return $^O eq 'MSWin32' ? lc($left) eq lc($right) : $left eq $right;
}

sub _source_chunk_count {
    my ($memories, $source, $digest) = @_;
    my $count = 0;
    for my $memory (@{$memories}) {
        $count++
            if ($memory->{kind} // '') eq 'file'
            && defined($memory->{source})
            && defined($memory->{digest})
            && _same_path($memory->{source}, $source)
            && $memory->{digest} eq $digest;
    }
    return $count;
}

sub _normalize_prompt {
    my ($text) = @_;
    $text = lc($text // '');
    $text =~ s/\s+/ /g;
    $text =~ s/\A\s+|\s+\z//g;
    return $text;
}

sub _keywords {
    my ($text) = @_;
    my %words;
    while (($text // '') =~ /([\p{L}\p{N}][\p{L}\p{N}'_-]*)/g) {
        my $word = lc $1;
        next if length($word) < 2 || $STOPWORD{$word};
        $words{$word} = 1;
    }
    return \%words;
}

sub _overlap {
    my ($query_words, $text) = @_;
    my $candidate_words = _keywords($text);
    my $score = 0;
    $score++ for grep { $candidate_words->{$_} } keys %{$query_words};
    return $score;
}

sub _retrieve {
    my (%args) = @_;
    my $query = $args{query};
    my $memories = $args{memories};

    my $exact = _exact_teaching($query, $memories);
    return $exact if defined $exact;

    my $query_words = _keywords($query);
    return undef if !keys %{$query_words};
    my $required_overlap = keys(%{$query_words}) > 1 ? 2 : 1;

    my ($best, $best_score, $best_priority, $best_index);
    for my $index (0 .. $#{$memories}) {
        my $memory = $memories->[$index];
        my $kind = $memory->{kind} // '';
        next if $kind ne 'teaching' && $kind ne 'file';
        my $searchable = $kind eq 'teaching'
            ? ($memory->{prompt} // '')
            : ($memory->{text} // '');
        my $score = _overlap($query_words, $searchable);
        next if $score < $required_overlap;
        if ($kind eq 'teaching') {
            my $prompt_words = _keywords($memory->{prompt} // '');
            # Fuzzy teaching recall is intentionally conservative: both the
            # question and taught prompt must be nearly the same.  Otherwise
            # shared phrases such as "launch code" can attach the answer to a
            # different subject.
            next if $score * 4 < keys(%{$query_words}) * 3;
            next if $score * 4 < keys(%{$prompt_words}) * 3;
        }
        my $priority = $kind eq 'teaching' ? 2 : 1;
        if (!defined($best)
            || $score > $best_score
            || ($score == $best_score && $priority > $best_priority)
            || ($score == $best_score && $priority == $best_priority
                && $index > $best_index)) {
            ($best, $best_score, $best_priority, $best_index) =
                ($memory, $score, $priority, $index);
        }
    }

    if (defined $best) {
        return $best->{text} if $best->{kind} eq 'teaching';
        my $excerpt = _best_excerpt($best->{text}, $query_words);
        return "From $best->{source}: $excerpt";
    }

    return undef if $args{no_conversation};
    my $question_fallback;
    for (my $index = $#{$memories}; $index >= 0; $index--) {
        my $memory = $memories->[$index];
        next if ($memory->{kind} // '') ne 'conversation';
        my $score = _overlap($query_words, $memory->{text} // '');
        next if $score < $required_overlap;
        next if $score * 4 < keys(%{$query_words}) * 3;
        if (_is_question_like($memory->{text})) {
            $question_fallback //= $memory;
            next;
        }
        my $excerpt = _shorten($memory->{text}, 300);
        return qq{Earlier you said: "$excerpt"};
    }
    if (defined $question_fallback) {
        my $excerpt = _shorten($question_fallback->{text}, 300);
        return qq{Earlier you said: "$excerpt"};
    }
    return undef;
}

sub _exact_teaching {
    my ($query, $memories) = @_;
    my $normalized = _normalize_prompt($query);
    for (my $index = $#{$memories}; $index >= 0; $index--) {
        my $memory = $memories->[$index];
        next if ($memory->{kind} // '') ne 'teaching';
        next if !defined $memory->{prompt};
        return $memory->{text}
            if _normalize_prompt($memory->{prompt}) eq $normalized;
    }
    return undef;
}

sub _best_excerpt {
    my ($text, $query_words) = @_;
    my @parts = grep { /\S/ } split /(?<=[.!?])\s+|\R+/, ($text // '');
    @parts = ($text // '') if !@parts;
    my $best = $parts[0];
    my $best_score = -1;
    for my $part (@parts) {
        my $score = _overlap($query_words, $part);
        if ($score > $best_score) {
            $best = $part;
            $best_score = $score;
        }
    }
    $best =~ s/\s+/ /g;
    $best =~ s/\A\s+|\s+\z//g;
    return _shorten($best, 360);
}

sub _shorten {
    my ($text, $limit) = @_;
    $text //= '';
    $text =~ s/\s+/ /g;
    $text =~ s/\A\s+|\s+\z//g;
    return $text if length($text) <= $limit;
    my $short = substr($text, 0, $limit - 3);
    $short =~ s/\s+\S*\z// if $short =~ /\s/;
    return $short . '...';
}

sub _latest_context_conversation {
    my ($memories) = @_;
    for (my $index = $#{$memories}; $index >= 0; $index--) {
        my $memory = $memories->[$index];
        next if ($memory->{kind} // '') ne 'conversation';
        my $candidate = $memory->{prompt} // $memory->{text};
        next if _is_followup($candidate);
        return $memory;
    }
    return undef;
}

sub _is_followup {
    my ($text) = @_;
    my $normalized = _normalize_prompt($text);
    $normalized =~ s/[.!?]+\z//;
    return $normalized =~ /\A(?:tell me more|more|go on|continue|what else|elaborate)\z/;
}

sub _is_greeting {
    my ($text) = @_;
    my $normalized = _normalize_prompt($text);
    $normalized =~ s/[!.?]+\z//;
    return $normalized =~ /\A(?:hi|hello|hey|good (?:morning|afternoon|evening))\z/;
}

sub _is_obvious_statement {
    my ($text) = @_;
    return 0 if ($text // '') =~ /\?\s*\z/;
    my $normalized = _normalize_prompt($text);
    $normalized =~ s/[.!]+\z//;
    return 1 if $normalized =~ /\Aremember that\s+\S/;
    return 1 if $normalized =~ /\Amy\s+.+\s+(?:is|are)\s+\S/;
    return 1 if $normalized =~ /\Ai\s+(?:am|like|love|prefer|live|work)\b\s*\S/;
    return 0;
}

sub _is_question_like {
    my ($text) = @_;
    return 1 if ($text // '') =~ /\?\s*\z/;
    my $normalized = _normalize_prompt($text);
    return $normalized =~ /\A(?:who|what|when|where|why|how|can|could|did|do|does|is|are|should|will|would)\b/;
}

sub _chunk_text {
    my ($text, $limit) = @_;
    $text =~ s/\r\n?/\n/g;
    $text =~ s/\A\s+|\s+\z//g;
    return () if $text eq '';

    my @paragraphs = grep { /\S/ } split /\n[\t ]*\n+/, $text;
    my @pieces;
    for my $paragraph (@paragraphs) {
        $paragraph =~ s/[\t ]+/ /g;
        $paragraph =~ s/\A\s+|\s+\z//g;
        push @pieces, _split_piece($paragraph, $limit);
    }

    my @chunks;
    my $current = '';
    for my $piece (@pieces) {
        if ($current eq '') {
            $current = $piece;
        }
        elsif (length($current) + 2 + length($piece) <= $limit) {
            $current .= "\n\n$piece";
        }
        else {
            push @chunks, $current;
            $current = $piece;
        }
    }
    push @chunks, $current if $current ne '';
    return @chunks;
}

sub _split_piece {
    my ($text, $limit) = @_;
    my @pieces;
    while (length($text) > $limit) {
        my $window = substr($text, 0, $limit);
        my $cut = rindex($window, ' ');
        $cut = $limit if $cut < int($limit / 2);
        my $piece = substr($text, 0, $cut, '');
        $piece =~ s/\A\s+|\s+\z//g;
        push @pieces, $piece if $piece ne '';
        $text =~ s/\A\s+//;
    }
    $text =~ s/\A\s+|\s+\z//g;
    push @pieces, $text if $text ne '';
    return @pieces;
}

1;

__END__

=head1 NAME

Alita::Agent - deterministic local conversation and file retrieval for TinyLLM

=head1 DESCRIPTION

This module stores user-provided teaching, conversation, and explicit local
UTF-8 file content in a TinyLLM model.  It performs deterministic retrieval;
it does not execute file content or access files that were not named by the
caller.

=cut
