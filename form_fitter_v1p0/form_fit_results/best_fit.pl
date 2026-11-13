#!/usr/bin/env perl
# Function evolved by form_fit.pl from .\sunspots.txt
#   y = -846281.22 - 57.464336 * cos(cos((x / (-1.5026)))) + 22.062626 * cos((x / (-1.33085))) + 47.831943 * sqrt((cos((x / (-1.67101))) + cos((x / (-1.35043))))) + 128563.65 * log((x + cos((x / (-1.7126))))) - 65.427682 * x + 9.9766353 * cos((x / (-1.49197)))
# Usage: perl best_fit.pl x1 x2 ...
use v5.36;
no warnings;

sub pdiv($l, $r) { abs($r) < 1e-12 ? 1 : $l / $r }
sub plog($v)     { $v == 0 ? 0 : log(abs $v) }
sub pexp($v)     { exp($v > 100 ? 100 : $v) }
sub psqrt($v)    { sqrt(abs $v) }

sub best_fit($x) { return -846281.2207931102 - 57.46433591662781 * cos(cos(main::pdiv($x, (-1.502600202304915)))) + 22.0626263940235 * cos(main::pdiv($x, (-1.3308483414212693))) + 47.831943485097064 * main::psqrt((cos(main::pdiv($x, (-1.6710102735472609))) + cos(main::pdiv($x, (-1.3504258828574709))))) + 128563.65108296982 * main::plog(($x + cos(main::pdiv($x, (-1.7126041962047005))))) - 65.427681805600457 * $x + 9.9766352649130035 * cos(main::pdiv($x, (-1.4919680371125534))) }

say "$_\t", best_fit($_) for @ARGV;
