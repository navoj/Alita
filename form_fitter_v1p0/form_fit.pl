#!/usr/bin/env perl
# form_fit.pl
# Jovan Trujillo
# 4/22/2013 - original: fit a data set by randomly forming and testing functions.
# 2026      - rewritten for modern Perl as a genetic-programming symbolic regressor.
#
# Candidate functions are expression trees. Each tree is compiled into a Perl
# closure with string eval, scored against the data, and evolved with
# tournament selection, subtree crossover and several mutation operators.
#
# Improvements over the original random search:
#   * Multi-term linear scaling: the tree is split at its top-level +/- nodes
#     into terms and y is fitted as a + b1*T1 + ... + bk*Tk by least squares,
#     so evolution only has to find the *shapes* of the terms.
#   * Constant tuning: the inner constants of the best individuals are refined
#     each generation by an adaptive hill climber (the original "C" idea).
#   * Protected operators (/, log, sqrt, exp) so no expression dies.
#   * Algebraic simplification, depth/size limits and parsimony pressure to
#     control bloat.
#   * Random immigrants when the search stagnates, and duplicate rejection.
#
# Usage: perl form_fit.pl [options] data.txt     (perl form_fit.pl --help)

use v5.36;
use Getopt::Long qw(GetOptions);
use List::Util qw(sum0 min max);
use Scalar::Util qw(looks_like_number);
use File::Path qw(make_path);
use File::Spec;

my %opt = (
    pop         => 400,
    gens        => 150,
    tournament  => 5,
    init_depth  => 5,
    max_depth   => 8,
    max_size    => 50,
    p_cross     => 0.70,
    p_mutate    => 0.25,
    elite       => 3,
    parsimony   => 0.01,
    pick_tol    => 0.10,
    max_terms   => 6,
    const_opt   => 5,
    const_steps => 25,
    stagnation  => 20,
    tol         => 1e-12,
    ops         => '+,-,*,/,sin,cos,exp,log,sqrt,abs',
    out         => 'form_fit_results',
    plot        => 1,
    seed        => undef,
    quiet       => 0,
);

sub usage {
    print <<"END";
Usage: perl form_fit.pl [options] <data file>

The data file holds two columns, x and y, separated by tabs, spaces or commas.

Options (defaults in brackets):
  --pop N          population size                          [$opt{pop}]
  --gens N         maximum generations                      [$opt{gens}]
  --tournament N   tournament size                          [$opt{tournament}]
  --init_depth N   max depth of initial random trees        [$opt{init_depth}]
  --max_depth N    max tree depth                           [$opt{max_depth}]
  --max_size N     max tree node count                      [$opt{max_size}]
  --p_cross P      crossover probability                    [$opt{p_cross}]
  --p_mutate P     mutation probability (rest = copy)       [$opt{p_mutate}]
  --elite N        elites copied unchanged                  [$opt{elite}]
  --parsimony K    relative fitness penalty per tree node   [$opt{parsimony}]
  --max_terms N    max additive terms given own coefficient [$opt{max_terms}]
  --pick_tol F     report simplest model within F of best error [$opt{pick_tol}]
  --const_opt N    individuals whose constants are tuned    [$opt{const_opt}]
  --const_steps N  hill-climb steps per tuned individual    [$opt{const_steps}]
  --stagnation N   generations without progress -> immigrants [$opt{stagnation}]
  --tol T          stop when normalised MSE < T             [$opt{tol}]
  --ops LIST       function set                             [$opt{ops}]
  --out DIR        output directory                         [$opt{out}]
  --[no]plot       write plots                              [on]
  --seed N         random seed for reproducible runs
  --quiet          less progress output
END
    exit 1;
}

GetOptions(\%opt,
    'pop=i', 'gens=i', 'tournament=i', 'init_depth=i', 'max_depth=i', 'max_size=i',
    'p_cross=f', 'p_mutate=f', 'elite=i', 'parsimony=f', 'max_terms=i', 'pick_tol=f', 'const_opt=i',
    'const_steps=i', 'stagnation=i', 'tol=f', 'ops=s', 'out=s', 'plot!', 'seed=i',
    'quiet!', 'help|h',
) or usage();
usage() if $opt{help} || @ARGV != 1;

# ---------------------------------------------------------------------------
# Function set. Protected versions keep every expression defined everywhere.
# ---------------------------------------------------------------------------
sub pdiv($l, $r) { abs($r) < 1e-12 ? 1 : $l / $r }
sub plog($v)     { $v == 0 ? 0 : log(abs $v) }
sub pexp($v)     { exp($v > 100 ? 100 : $v) }
sub psqrt($v)    { sqrt(abs $v) }

my %IMPL = (
    '+'  => sub ($l, $r) { $l + $r },
    '-'  => sub ($l, $r) { $l - $r },
    '*'  => sub ($l, $r) { $l * $r },
    '/'  => \&pdiv,
    sin  => sub ($v) { sin $v },
    cos  => sub ($v) { cos $v },
    abs  => sub ($v) { abs $v },
    exp  => \&pexp,
    log  => \&plog,
    sqrt => \&psqrt,
);
my %ARITY = ('+' => 2, '-' => 2, '*' => 2, '/' => 2,
             map { $_ => 1 } qw(sin cos abs exp log sqrt));

my @FUNCS = split /\s*,\s*/, $opt{ops};
for my $f (@FUNCS) {
    die "Unknown operator '$f' (allowed: @{[ sort keys %ARITY ]})\n" unless $ARITY{$f};
}
die "Need at least one operator\n" unless @FUNCS;

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
my $datafile = $ARGV[0];
my (@X, @Y);
open my $fh, '<', $datafile or die "Could not open $datafile: $!\n";
while (my $line = <$fh>) {
    $line =~ s/^\s+|\s+$//g;
    next if $line eq '' || $line =~ /^#/;
    my ($x, $y) = split /[\s,]+/, $line;
    next unless defined $y && looks_like_number($x) && looks_like_number($y);
    push @X, $x + 0;
    push @Y, $y + 0;
}
close $fh;
die "Need at least 3 data points in $datafile\n" if @X < 3;

my $N     = @X;
my $ymean = sum0(@Y) / $N;
my $yvar  = sum0(map { ($_ - $ymean)**2 } @Y) / $N;
$yvar = 1 if $yvar < 1e-300;

my $seed = defined $opt{seed} ? srand($opt{seed}) : srand();
say "form_fit.pl started: $N points from $datafile, seed $seed";

# ---------------------------------------------------------------------------
# Trees: ['x'], ['c', value] or [op, child, (child)]
# ---------------------------------------------------------------------------
sub is_term($n)   { $n->[0] eq 'x' || $n->[0] eq 'c' }
sub is_finite($v) { $v == $v && abs($v) < 1e100 }

sub copy_tree($n) {
    return [@$n] if is_term($n);
    return [$n->[0], map { copy_tree($_) } @{$n}[1 .. $#$n]];
}

sub tree_size($n) {
    return 1 if is_term($n);
    return 1 + sum0(map { tree_size($_) } @{$n}[1 .. $#$n]);
}

sub tree_depth($n) {
    return 0 if is_term($n);
    return 1 + max(map { tree_depth($_) } @{$n}[1 .. $#$n]);
}

sub fmt_num($v, $p = 17) {
    my $s = sprintf "%.${p}g", $v;
    return $v < 0 ? "($s)" : $s;
}

# Perl source used for compilation (and as the cache key).
sub to_perl($n) {
    my $op = $n->[0];
    return '$x' if $op eq 'x';
    return fmt_num($n->[1]) if $op eq 'c';
    my @c = map { to_perl($_) } @{$n}[1 .. $#$n];
    return "($c[0] $op $c[1])" if $op eq '+' || $op eq '-' || $op eq '*';
    return "main::pdiv($c[0], $c[1])" if $op eq '/';
    return "$op($c[0])" if $op eq 'sin' || $op eq 'cos' || $op eq 'abs';
    return "main::p$op($c[0])";
}

# Human readable infix.
sub to_infix($n) {
    my $op = $n->[0];
    return 'x' if $op eq 'x';
    return fmt_num($n->[1], 6) if $op eq 'c';
    my @c = map { to_infix($_) } @{$n}[1 .. $#$n];
    return "($c[0] $op $c[1])" if @c == 2;
    return "$op($c[0])";
}

sub eval_tree($n, $x) {
    my $op = $n->[0];
    return $x if $op eq 'x';
    return $n->[1] if $op eq 'c';
    no warnings;
    return $IMPL{$op}->(map { eval_tree($_, $x) } @{$n}[1 .. $#$n]);
}

sub random_terminal() {
    return rand() < 0.6 ? ['x'] : ['c', sprintf('%.2f', -5 + 10 * rand()) + 0];
}

# "full" builds complete trees; otherwise "grow" stops early at random.
sub random_tree($depth, $full) {
    return random_terminal() if $depth <= 0 || (!$full && rand() < 0.3);
    my $f = $FUNCS[rand @FUNCS];
    return [$f, map { random_tree($depth - 1, $full) } 1 .. $ARITY{$f}];
}

# Every node position as [container, index]; the root lives in $holder->[0].
sub slots($holder) {
    my (@out, @stack);
    @stack = ([$holder, 0]);
    while (my $s = pop @stack) {
        push @out, $s;
        my $n = $s->[0][$s->[1]];
        push @stack, map { [$n, $_] } 1 .. $#$n unless is_term($n);
    }
    return @out;
}

# Koza-style choice: prefer internal nodes 90% of the time.
sub pick_slot($holder) {
    my @all = slots($holder);
    my @internal = grep { !is_term($_->[0][$_->[1]]) } @all;
    return @internal && rand() < 0.9 ? $internal[rand @internal] : $all[rand @all];
}

sub within_limits($t) {
    return tree_depth($t) <= $opt{max_depth} && tree_size($t) <= $opt{max_size};
}

sub same_tree($l, $r) { to_perl($l) eq to_perl($r) }

# Constant folding and identity removal.
sub simplify($n) {
    return $n if is_term($n);
    my $op = $n->[0];
    my @k  = map { simplify($_) } @{$n}[1 .. $#$n];

    unless (grep { $_->[0] ne 'c' } @k) {
        no warnings;
        my $v = $IMPL{$op}->(map { $_->[1] } @k);
        return ['c', $v] if is_finite($v);
    }
    if (@k == 2) {
        my ($l, $r) = @k;
        my $lc = $l->[0] eq 'c' ? $l->[1] : undef;
        my $rc = $r->[0] eq 'c' ? $r->[1] : undef;
        if ($op eq '+') {
            return $r if defined $lc && $lc == 0;
            return $l if defined $rc && $rc == 0;
        }
        elsif ($op eq '-') {
            return $l if defined $rc && $rc == 0;
            return ['c', 0] if same_tree($l, $r);
        }
        elsif ($op eq '*') {
            return $r if defined $lc && $lc == 1;
            return $l if defined $rc && $rc == 1;
            return ['c', 0] if (defined $lc && $lc == 0) || (defined $rc && $rc == 0);
        }
        elsif ($op eq '/') {
            return $l if defined $rc && $rc == 1;
            return ['c', 1] if same_tree($l, $r);
        }
    }
    return [$op, @k];
}

# ---------------------------------------------------------------------------
# Fitness: multi-term linear scaling. The tree is split at its top-level
# +/- nodes into terms T1..Tk and y is fitted as a + b1*T1 + ... + bk*Tk by
# least squares, so evolution only has to discover the *shapes* of the terms.
# The normalised MSE is inflated by a relative parsimony penalty so tree size
# never outweighs a real accuracy gain.
# ---------------------------------------------------------------------------
my %cache;
my $evaluations = 0;
my %BAD = (nmse => 1e100, a => 0, coefs => []);

sub has_x($n) {
    return $n->[0] eq 'x' if is_term($n);
    return !!grep { has_x($_) } @{$n}[1 .. $#$n];
}

# Constant terms are dropped: the intercept absorbs them.
sub terms_of($tree) {
    my @t;
    my @stack = ($tree);
    while (my $n = shift @stack) {
        if ($n->[0] eq '+' || $n->[0] eq '-') { push @stack, $n->[1], $n->[2] }
        elsif (has_x($n))                      { push @t, $n }
    }
    return @t <= $opt{max_terms} ? @t : has_x($tree) ? ($tree) : ();
}

# Solve the (small) symmetric system G b = r with partial pivoting.
sub solve($G, $r) {
    my $k = @$r;
    my @m = map { [@{ $G->[$_] }, $r->[$_]] } 0 .. $k - 1;
    for my $c (0 .. $k - 1) {
        my ($p) = sort { abs($m[$b][$c]) <=> abs($m[$a][$c]) } $c .. $k - 1;
        @m[$c, $p] = @m[$p, $c];
        return if abs($m[$c][$c]) < 1e-300;
        for my $i ($c + 1 .. $k - 1) {
            my $f = $m[$i][$c] / $m[$c][$c];
            $m[$i][$_] -= $f * $m[$c][$_] for $c .. $k;
        }
    }
    my @x;
    for my $i (reverse 0 .. $k - 1) {
        my $s = $m[$i][$k];
        $s -= $m[$i][$_] * $x[$_] for $i + 1 .. $k - 1;
        $x[$i] = $s / $m[$i][$i];
    }
    return \@x;
}

sub score_tree($tree) {
    $evaluations++;
    my @terms = terms_of($tree);
    return { nmse => 1, a => $ymean, coefs => [] } unless @terms;

    my (@cols, @means);
    for my $t (@terms) {
        my $code = to_perl($t);
        my $f = eval "sub { no warnings; my \$x = shift; $code }" or return {%BAD};
        my @p;
        for my $x (@X) {
            my $v = $f->($x);
            return {%BAD} unless is_finite($v);
            push @p, $v;
        }
        my $pm = sum0(@p) / $N;
        push @means, $pm;
        push @cols, [map { $_ - $pm } @p];
    }
    my $k = @cols;
    my (@G, @r);
    for my $i (0 .. $k - 1) {
        my $ci = $cols[$i];
        $r[$i] = sum0(map { $ci->[$_] * ($Y[$_] - $ymean) } 0 .. $N - 1);
        for my $j ($i .. $k - 1) {
            my $cj = $cols[$j];
            $G[$i][$j] = $G[$j][$i] = sum0(map { $ci->[$_] * $cj->[$_] } 0 .. $N - 1);
        }
    }
    # Tiny ridge keeps duplicated/collinear terms solvable; a (numerically)
    # constant term gets no weight at all.
    my $maxd = max(map { $G[$_][$_] } 0 .. $k - 1);
    for my $i (0 .. $k - 1) {
        if ($G[$i][$i] / $N <= 1e-20 * (1 + $means[$i]**2)) {
            $G[$i][$_] = $G[$_][$i] = 0 for 0 .. $k - 1;
            $G[$i][$i] = 1;
            $r[$i] = 0;
        }
        else { $G[$i][$i] += 1e-12 * $maxd }
    }
    my $b = solve(\@G, \@r) or return {%BAD};
    my $a = $ymean - sum0(map { $b->[$_] * $means[$_] } 0 .. $k - 1);
    my $sse = 0;
    for my $n (0 .. $N - 1) {
        my $e = $Y[$n] - $ymean;
        $e -= $b->[$_] * $cols[$_][$n] for 0 .. $k - 1;
        $sse += $e * $e;
    }
    my $nmse = $sse / $N / $yvar;
    return is_finite($nmse) ? { nmse => $nmse, a => $a, coefs => $b } : {%BAD};
}

sub evaluate($tree) {
    my $s    = $cache{ to_perl($tree) } //= score_tree($tree);
    my $size = tree_size($tree);
    return { %$s, tree => $tree, size => $size,
             fitness => $s->{nmse} * (1 + $opt{parsimony} * $size) };
}

sub by_fitness { $a->{fitness} <=> $b->{fitness} || $a->{size} <=> $b->{size} }

# ---------------------------------------------------------------------------
# Genetic operators
# ---------------------------------------------------------------------------
sub tournament($pop) {
    my $best;
    for (1 .. $opt{tournament}) {
        my $c = $pop->[rand @$pop];
        $best = $c if !$best || $c->{fitness} < $best->{fitness};
    }
    return $best;
}

sub crossover($p1, $p2) {
    for (1 .. 5) {
        my $h = [copy_tree($p1)];
        my $s = pick_slot($h);
        my $d = pick_slot([$p2]);
        $s->[0][$s->[1]] = copy_tree($d->[0][$d->[1]]);
        return $h->[0] if within_limits($h->[0]);
    }
    return copy_tree($p1);
}

sub gauss() {
    my ($u1, $u2) = (1 - rand(), rand());
    return sqrt(-2 * log $u1) * cos(6.283185307179586 * $u2);
}

sub const_nodes($t) {
    return grep { $_->[0] eq 'c' } map { $_->[0][$_->[1]] } slots([$t]);
}

sub mutate($p) {
    for (1 .. 5) {
        my $h = [copy_tree($p)];
        my $s = pick_slot($h);
        my $n = $s->[0][$s->[1]];
        my $r = rand();
        if ($r < 0.35) {                              # subtree replacement
            $s->[0][$s->[1]] = random_tree(int rand 4, 0);
        }
        elsif ($r < 0.60) {                           # point mutation
            if ($n->[0] eq 'x') { $s->[0][$s->[1]] = random_terminal() }
            elsif ($n->[0] eq 'c') { $s->[0][$s->[1]] = ['x'] }
            else {
                my @same = grep { $ARITY{$_} == $ARITY{$n->[0]} } @FUNCS;
                $n->[0] = $same[rand @same];
            }
        }
        elsif ($r < 0.85) {                           # constant jitter
            my @c = const_nodes($h->[0]);
            if (@c) { $_->[1] += gauss() * (0.1 * abs($_->[1]) + 0.1) for @c }
            else    { $s->[0][$s->[1]] = random_tree(int rand 3, 0) }
        }
        else {                                        # hoist / shrink
            $s->[0][$s->[1]] = is_term($n) ? random_terminal() : $n->[1 + int rand $#$n];
        }
        return $h->[0] if within_limits($h->[0]);
    }
    return copy_tree($p);
}

# Adaptive (1/5th-rule style) hill climb on the tree's constants.
sub tune_constants($ind, $steps = $opt{const_steps}, $sigma = 0.3) {
    return $ind unless const_nodes($ind->{tree});
    my $best  = $ind;
    for (1 .. $steps) {
        my $t = copy_tree($best->{tree});
        my @c = const_nodes($t);
        my @pick = rand() < 0.5 ? ($c[rand @c]) : @c;
        $_->[1] += $sigma * gauss() * max(abs($_->[1]), 0.1) for @pick;
        my $cand = evaluate($t);
        if ($cand->{fitness} < $best->{fitness}) { $best = $cand; $sigma *= 1.5 }
        else                                     { $sigma *= 0.85 }
        last if $sigma < 1e-12;
    }
    return $best;
}

sub random_population($n) {
    my (@pop, %seen);
    my $tries = 0;
    while (@pop < $n) {
        my $depth = 2 + int rand max(1, $opt{init_depth} - 1);
        my $t = simplify(random_tree($depth, rand() < 0.5));
        my $key = to_perl($t);
        next if $seen{$key}++ && ++$tries < 20 * $n;   # favour unique individuals
        push @pop, evaluate($t);
    }
    return @pop;
}

# ---------------------------------------------------------------------------
# Evolution
# ---------------------------------------------------------------------------
my @pop = random_population($opt{pop});
my (@history, $best_ever, %archive);
my $stale = 0;
my $t0    = time;

for my $gen (0 .. $opt{gens}) {
    @pop = sort by_fitness @pop;
    my $k = min($opt{const_opt}, scalar @pop);
    $pop[$_] = tune_constants($pop[$_]) for 0 .. $k - 1;
    @pop = sort by_fitness @pop;

    # Pareto archive: most accurate individual seen for every tree size.
    for my $ind (@pop) {
        my $cur = $archive{ $ind->{size} };
        $archive{ $ind->{size} } = $ind if !$cur || $ind->{nmse} < $cur->{nmse};
    }

    my $improved = !$best_ever || $pop[0]{fitness} < $best_ever->{fitness} * (1 - 1e-9);
    if ($improved) { $best_ever = $pop[0]; $stale = 0 } else { $stale++ }

    my @valid = sort { $a <=> $b } map { $_->{nmse} } grep { $_->{nmse} < 1e100 } @pop;
    push @history, {
        gen    => $gen,
        best   => $best_ever->{nmse},
        median => @valid ? $valid[$#valid / 2] : 1e100,
        size   => $best_ever->{size},
    };

    if (!$opt{quiet} && ($improved || $gen % 10 == 0)) {
        my $e = to_infix($best_ever->{tree});
        $e = substr($e, 0, 67) . '...' if length $e > 70;
        printf "gen %4d  NMSE %.4e  size %2d  %s\n", $gen, $best_ever->{nmse}, $best_ever->{size}, $e;
    }
    last if $best_ever->{nmse} < $opt{tol} || $gen == $opt{gens};

    if ($stale >= $opt{stagnation}) {
        say "gen $gen: stagnation, injecting random immigrants" unless $opt{quiet};
        my $keep = int(@pop / 2);
        splice @pop, $keep, @pop - $keep, random_population(@pop - $keep);
        $stale = 0;
    }

    my @next = map { $pop[$_] } 0 .. min($opt{elite}, scalar @pop) - 1;
    my %seen = map { to_perl($_->{tree}) => 1 } @next;
    while (@next < $opt{pop}) {
        my $r = rand();
        my $child =
              $r < $opt{p_cross}                   ? crossover(tournament(\@pop)->{tree}, tournament(\@pop)->{tree})
            : $r < $opt{p_cross} + $opt{p_mutate} ? mutate(tournament(\@pop)->{tree})
            :                                       copy_tree(tournament(\@pop)->{tree});
        $child = simplify($child);
        # Reject duplicates to keep the population diverse.
        for (1 .. 3) {
            last unless $seen{ to_perl($child) };
            $child = simplify(mutate($child));
        }
        $seen{ to_perl($child) } = 1;
        push @next, evaluate($child);
    }
    @pop = @next;
    %cache = () if keys %cache > 200_000;
}

# ---------------------------------------------------------------------------
# Model selection: polish the non-dominated (size, error) models, then report
# the simplest one whose error is within --pick_tol of the most accurate.
# ---------------------------------------------------------------------------
my @front;
for my $size (sort { $a <=> $b } keys %archive) {
    my $ind = $archive{$size};
    push @front, $ind if !@front || $ind->{nmse} < $front[-1]{nmse};
}
@front = map { tune_constants($_, 10 * $opt{const_steps}) } @front;
my $min_nmse = min(map { $_->{nmse} } @front);
my $limit    = max($min_nmse * (1 + $opt{pick_tol}), $opt{tol});
my ($best)   = grep { $_->{nmse} <= $limit } @front;

$best = tune_constants($best, 40 * $opt{const_steps});    # final polish
for my $sigma (1e-2, 1e-4, 1e-6) {    # restart the climber with ever smaller steps
    last if $best->{nmse} < $opt{tol};
    $best = tune_constants($best, 10 * $opt{const_steps}, $sigma);
}
my @terms = terms_of($best->{tree});
my ($A, @C) = ($best->{a}, @{ $best->{coefs} });

# Render a + c1*T1 + ... for an individual, using $render for each term tree.
sub model_text($ind, $render, $prec) {
    my @t = terms_of($ind->{tree});
    my @c = @{ $ind->{coefs} };
    my @parts;
    push @parts, [$ind->{a}, undef] if abs($ind->{a}) >= 1e-12 || !@t;
    push @parts, map { [$c[$_], $t[$_]] } grep { $c[$_] != 0 } 0 .. $#t;
    my $s = '';
    for my $i (0 .. $#parts) {
        my ($c, $t) = @{ $parts[$i] };
        my $mag  = sprintf "%.${prec}g", abs $c;
        my $body = !defined $t              ? $mag
                 : abs(abs($c) - 1) < 1e-12 ? $render->($t)
                 :                            "$mag * " . $render->($t);
        $s .= $i == 0 ? ($c < 0 ? "-$body" : $body) : ($c < 0 ? " - $body" : " + $body");
    }
    return $s eq '' ? '0' : $s;
}
my $expr      = 'y = ' . model_text($best, \&to_infix, 8);
my $perl_expr = model_text($best, \&to_perl, 17);
my $mse       = $best->{nmse} * $yvar;
my $elapsed   = time - $t0;

my $report = <<"END";
Best function found ($history[-1]{gen} generations, $evaluations evaluations, ${elapsed}s, seed $seed)
  $expr
  NMSE = @{[ sprintf '%.6e', $best->{nmse} ]}   MSE = @{[ sprintf '%.6e', $mse ]}   RMSE = @{[ sprintf '%.6e', sqrt $mse ]}   R^2 = @{[ sprintf '%.8f', 1 - $best->{nmse} ]}
  tree size $best->{size}, depth @{[ tree_depth($best->{tree}) ]}, @{[ scalar @terms ]} linearly scaled term(s)
  (simplest model within @{[ 100 * $opt{pick_tol} ]}% of the lowest error found, @{[ sprintf '%.3e', $min_nmse ]})
  ('/', 'log', 'sqrt' and 'exp' are protected: x/0 -> 1, log|x|, sqrt|x|, exp capped at e^100)
END
print "\n$report";

my $front_text = "Pareto front (size, NMSE, model):\n"
    . join('', map { sprintf "  %3d  %.4e  y = %s\n", $_->{size}, $_->{nmse}, model_text($_, \&to_infix, 6) } @front);

make_path($opt{out});
my $outfile = sub ($name) { File::Spec->catfile($opt{out}, $name) };

open my $rfh, '>', $outfile->('result.txt') or die "Cannot write result: $!\n";
print $rfh $report, "\n", $front_text;
print "\n$front_text" unless $opt{quiet};
close $rfh;

open my $pfh, '>', $outfile->('best_fit.pl') or die "Cannot write best_fit.pl: $!\n";
print $pfh <<"END";
#!/usr/bin/env perl
# Function evolved by form_fit.pl from $datafile
#   $expr
# Usage: perl best_fit.pl x1 x2 ...
use v5.36;
no warnings;

sub pdiv(\$l, \$r) { abs(\$r) < 1e-12 ? 1 : \$l / \$r }
sub plog(\$v)     { \$v == 0 ? 0 : log(abs \$v) }
sub pexp(\$v)     { exp(\$v > 100 ? 100 : \$v) }
sub psqrt(\$v)    { sqrt(abs \$v) }

sub best_fit(\$x) { return $perl_expr }

say "\$_\\t", best_fit(\$_) for \@ARGV;
END
close $pfh;

open my $hfh, '>', $outfile->('history.txt') or die "Cannot write history: $!\n";
say $hfh "# gen\tbest_nmse\tmedian_nmse\tbest_size";
say $hfh join "\t", @{$_}{qw(gen best median size)} for @history;
close $hfh;

my $best_f = sub ($x) { $A + sum0(map { $C[$_] * eval_tree($terms[$_], $x) } 0 .. $#terms) };
if ($opt{plot}) {
    my ($xmin, $xmax) = (min(@X), max(@X));
    my @cx = map { $xmin + ($xmax - $xmin) * $_ / 1000 } 0 .. 1000;
    my @cy = map { my $v = $best_f->($_); is_finite($v) ? $v : 'nan' } @cx;

    svg_plot(
        file   => $outfile->('fit.svg'),
        title  => "form_fit: $expr",
        xlabel => 'x', ylabel => 'y',
        series => [
            { x => \@cx, y => \@cy, type => 'line',   color => '#d62728', label => 'evolved function' },
            { x => \@X,  y => \@Y,  type => 'points', color => '#1f77b4', label => 'data' },
        ],
    );
    svg_plot(
        file   => $outfile->('convergence.svg'),
        title  => 'Convergence (normalised MSE)',
        xlabel => 'generation', ylabel => 'NMSE', logy => 1,
        series => [
            { x => [map { $_->{gen} } @history], y => [map { $_->{best} } @history],
              type => 'line', color => '#d62728', label => 'best' },
            { x => [map { $_->{gen} } @history], y => [map { $_->{median} } @history],
              type => 'line', color => '#7f7f7f', label => 'population median' },
        ],
    );
    gnuplot_png(\@cx, \@cy, $expr);
}
say "Results written to $opt{out}";

# ---------------------------------------------------------------------------
# Plotting: dependency-free SVG, plus PNG via gnuplot when it is installed.
# ---------------------------------------------------------------------------
sub nice_ticks($lo, $hi, $n = 8) {
    my $range = $hi - $lo || 1;
    my $raw   = $range / $n;
    my $mag   = 10**int(log($raw) / log(10) - ($raw < 1 ? 1 : 0));
    my ($step) = grep { $_ >= $raw } map { $_ * $mag } 1, 2, 2.5, 5, 10, 20;
    $step ||= $raw;
    my @t;
    for (my $v = $step * int($lo / $step - ($lo < 0 ? 1 : 0)); $v <= $hi + 1e-9 * $range; $v += $step) {
        push @t, abs($v) < 1e-12 * $step ? 0 : $v if $v >= $lo - 1e-9 * $range;
    }
    return @t;
}

sub xml_escape($s) { $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s }

sub svg_plot(%a) {
    my ($W, $H, $L, $R, $T, $Bm) = (1000, 560, 80, 30, 50, 60);
    my $ty = $a{logy} ? sub ($v) { log(max($v, 1e-300)) / log(10) } : sub ($v) { $v };
    my (@xs, @ys);
    for my $s (@{ $a{series} }) {
        for my $i (0 .. $#{ $s->{x} }) {
            my $y = $s->{y}[$i];
            next unless looks_like_number($y) && is_finite($y) && (!$a{logy} || $y > 0);
            push @xs, $s->{x}[$i];
            push @ys, $ty->($y);
        }
    }
    return unless @xs;
    my ($x0, $x1, $y0, $y1) = (min(@xs), max(@xs), min(@ys), max(@ys));
    ($x0, $x1) = ($x0 - 1, $x1 + 1) if $x1 == $x0;
    ($y0, $y1) = ($y0 - 1, $y1 + 1) if $y1 == $y0;
    my $pad = 0.05 * ($y1 - $y0);
    ($y0, $y1) = ($y0 - $pad, $y1 + $pad);
    if ($a{logy}) { $y0 = int($y0) - ($y0 < 0 ? 1 : 0); $y1 = int($y1) + 1 }
    my $px = sub ($v) { $L + ($v - $x0) / ($x1 - $x0) * ($W - $L - $R) };
    my $py = sub ($v) { $H - $Bm - ($v - $y0) / ($y1 - $y0) * ($H - $T - $Bm) };

    my @svg = (qq{<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" font-family="Arial, sans-serif" font-size="12">},
               qq{<rect width="100%" height="100%" fill="white"/>});
    for my $v (nice_ticks($x0, $x1)) {
        my $X = sprintf '%.1f', $px->($v);
        push @svg, qq{<line x1="$X" y1="$T" x2="$X" y2="@{[$H-$Bm]}" stroke="#e5e5e5"/>},
                   qq{<text x="$X" y="@{[$H-$Bm+18]}" text-anchor="middle">@{[0+sprintf '%.6g', $v]}</text>};
    }
    my @yt = $a{logy}
        ? do { my $st = max(1, int(($y1 - $y0) / 8 + 0.999)); grep { $_ % $st == 0 } int($y0) .. int($y1) }
        : nice_ticks($y0, $y1);
    for my $v (@yt) {
        my $Y = sprintf '%.1f', $py->($v);
        my $lab = $a{logy} ? "1e$v" : 0 + sprintf '%.6g', $v;
        push @svg, qq{<line x1="$L" y1="$Y" x2="@{[$W-$R]}" y2="$Y" stroke="#e5e5e5"/>},
                   qq{<text x="@{[$L-8]}" y="@{[$Y+4]}" text-anchor="end">$lab</text>};
    }
    push @svg, qq{<rect x="$L" y="$T" width="@{[$W-$L-$R]}" height="@{[$H-$T-$Bm]}" fill="none" stroke="black"/>};

    for my $s (@{ $a{series} }) {
        my @seg = ([]);
        for my $i (0 .. $#{ $s->{x} }) {
            my $y = $s->{y}[$i];
            if (looks_like_number($y) && is_finite($y) && (!$a{logy} || $y > 0)) {
                my $Y = min(max($py->($ty->($y)), $T), $H - $Bm);
                push @{ $seg[-1] }, sprintf('%.2f,%.2f', $px->($s->{x}[$i]), $Y);
            }
            else { push @seg, [] }
        }
        if ($s->{type} eq 'points') {
            push @svg, map { my ($cx, $cy) = split /,/; qq{<circle cx="$cx" cy="$cy" r="3.5" fill="$s->{color}"/>} } map { @$_ } @seg;
        }
        else {
            push @svg, map { qq{<polyline fill="none" stroke="$s->{color}" stroke-width="1.6" points="@$_"/>} } grep { @$_ > 1 } @seg;
        }
    }
    my $ly = $T + 18;
    for my $s (@{ $a{series} }) {
        my $lx = $W - $R - 170;
        push @svg, $s->{type} eq 'points'
            ? qq{<circle cx="@{[$lx+12]}" cy="@{[$ly-4]}" r="3.5" fill="$s->{color}"/>}
            : qq{<line x1="$lx" y1="@{[$ly-4]}" x2="@{[$lx+24]}" y2="@{[$ly-4]}" stroke="$s->{color}" stroke-width="2"/>};
        push @svg, qq{<text x="@{[$lx+32]}" y="$ly">@{[xml_escape($s->{label})]}</text>};
        $ly += 18;
    }
    my $title = $a{title};
    $title = substr($title, 0, 137) . '...' if length $title > 140;
    push @svg,
        qq{<text x="@{[$W/2]}" y="28" text-anchor="middle" font-size="14" font-weight="bold">@{[xml_escape($title)]}</text>},
        qq{<text x="@{[($L+$W-$R)/2]}" y="@{[$H-15]}" text-anchor="middle">@{[xml_escape($a{xlabel})]}</text>},
        qq{<text x="20" y="@{[($T+$H-$Bm)/2]}" text-anchor="middle" transform="rotate(-90 20 @{[($T+$H-$Bm)/2]})">@{[xml_escape($a{ylabel})]}</text>},
        '</svg>';
    open my $out, '>', $a{file} or die "Cannot write $a{file}: $!\n";
    say $out join "\n", @svg;
    close $out;
}

sub gnuplot_png($cx, $cy, $title) {
    my $data  = $outfile->('data.dat');
    my $curve = $outfile->('curve.dat');
    my $gp    = $outfile->('plot.gp');
    open my $d, '>', $data or return;
    say $d "$X[$_]\t$Y[$_]" for 0 .. $#X;
    close $d;
    open my $c, '>', $curve or return;
    say $c "$cx->[$_]\t$cy->[$_]" for 0 .. $#$cx;
    close $c;

    (my $q = $title) =~ s/(["\\])/\\$1/g;
    $q = substr($q, 0, 117) . '...' if length $q > 120;
    my %f = map { $_ => do { (my $p = $outfile->($_)) =~ s{\\}{/}g; $p } }
            qw(data.dat curve.dat history.txt fit.png convergence.png);
    open my $g, '>', $gp or return;
    print $g <<"END";
if (strstrt(GPVAL_TERMINALS, "pngcairo") > 0) { set terminal pngcairo size 1100,600 font "Arial,10" } else { set terminal png size 1100,600 }
set datafile missing "nan"
set grid
set key top right
set output "$f{'fit.png'}"
set title "form_fit: $q" noenhanced
set xlabel "x"
set ylabel "y"
plot "$f{'curve.dat'}" using 1:2 with lines lw 2 lc rgb "#d62728" title "evolved function", \\
     "$f{'data.dat'}" using 1:2 with points pt 7 ps 0.8 lc rgb "#1f77b4" title "data"
set output "$f{'convergence.png'}"
set title "Convergence (normalised MSE)"
set xlabel "generation"
set ylabel "NMSE"
set logscale y
set xrange [0:@{[ max(1, $history[-1]{gen}) ]}]
set format y "%.0e"
plot "$f{'history.txt'}" using 1:2 with lines lw 2 lc rgb "#d62728" title "best", \\
     "$f{'history.txt'}" using 1:3 with lines lw 2 lc rgb "#7f7f7f" title "population median"
END
    close $g;
    my $rc = system('gnuplot', $gp);
    say $rc == 0 ? "gnuplot PNGs written" : "gnuplot not available; SVG plots only" unless $opt{quiet};
}
