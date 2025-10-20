package TinyLLM;
use strict;
use warnings;
use Storable qw(nstore retrieve);
use File::Spec;
use File::Path qw(make_path);

our $VERSION = '0.1';

sub new {
    my ($class, %args) = @_;
    my $path = $args{path} // 'myBrainLLM.dat';

    my $self = {
        path         => $path,
        unigrams     => {},
        bigrams      => {},
        total_tokens => 0,
        version      => $VERSION,
    };

    if (-e $path) {
        my $loaded = eval { retrieve($path) };
        if ($loaded && ref $loaded eq 'HASH' && $loaded->{bigrams} && $loaded->{unigrams}) {
            # Merge any missing keys to keep forward compatibility
            $self->{$_} = $loaded->{$_] } for keys %$loaded;
        }
    }

    bless $self, $class;
    return $self;
}

sub save {
    my ($self) = @_;
    my $path = $self->{path};

    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    my $dirpath = File::Spec->catpath($vol, $dir, '');
    if ($dirpath && !-d $dirpath) {
        make_path($dirpath);
    }

    my $tmp = "$path.tmp.$$";
    nstore($self, $tmp) or die "Failed to write $tmp: $!";
    rename $tmp, $path or die "Failed to move $tmp to $path: $!";
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

    # Apply temperature: p_i^(1/T) then renormalize
    my %adj;
    my $sum = 0.0;
    for my $k (keys %$dist) {
        my $p = $dist->{$k};
        my $q = $p ** (1.0 / $temperature);
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

1;

__END__

=pod

=head1 NAME

TinyLLM - A tiny bigram language model for interactive training and reply generation

=head1 SYNOPSIS

  use lib 'lib';
  use TinyLLM;

  my $llm = TinyLLM->new(path => 'myBrainLLM.dat');
  $llm->train("Hello there, how are you?");
  $llm->save();

  my $reply = $llm->reply(prompt => "Hello", max_tokens => 40, temperature => 0.8);
  print "$reply\n";

=head1 DESCRIPTION

A minimal bigram-based "tiny LLM" that can be incrementally trained from
conversational input and persisted to C<myBrainLLM.dat>. It provides:

=over 4

=item * C<train($text)> to update the model with new text.

=item * C<reply(prompt => $text, max_tokens => N, temperature => T)> to generate a response.

=item * C<save()> to persist the model; it automatically loads from the given path on C<new>.

=back

=cut
