#!/usr/bin/env perl
# Function evolved by form_fit.pl from .\KevinDUT2.txt
#   y = 30115.664 - 259.95988 * sqrt((sin(sqrt(sqrt(sqrt(abs(x))))) / (1.8592 / x))) + 15340.137 * (sqrt(sqrt(x)) / (0.00479754 / x)) + 26.798005 * sqrt(sqrt(x)) - 71975.461 * sqrt((sqrt((x - abs(x))) - (-0.00995946))) + 203.79192 * sqrt(sqrt((x - abs(x)))) - 22901.38 * (((-0.101542) / x) / ((-0.101403) / x))
# Usage: perl best_fit.pl x1 x2 ...
use v5.36;
no warnings;

sub pdiv($l, $r) { abs($r) < 1e-12 ? 1 : $l / $r }
sub plog($v)     { $v == 0 ? 0 : log(abs $v) }
sub pexp($v)     { exp($v > 100 ? 100 : $v) }
sub psqrt($v)    { sqrt(abs $v) }

sub best_fit($x) { return 30115.663808077159 - 259.95987795639661 * main::psqrt(main::pdiv(sin(main::psqrt(main::psqrt(main::psqrt(abs($x))))), main::pdiv(1.8591972520512647, $x))) + 15340.137414614903 * main::pdiv(main::psqrt(main::psqrt($x)), main::pdiv(0.0047975369091151241, $x)) + 26.798004946610618 * main::psqrt(main::psqrt($x)) - 71975.46084815124 * main::psqrt((main::psqrt(($x - abs($x))) - (-0.0099594558952841254))) + 203.79192013106146 * main::psqrt(main::psqrt(($x - abs($x)))) - 22901.379996064319 * main::pdiv(main::pdiv((-0.1015417706966452), $x), main::pdiv((-0.101403492759516), $x)) }

say "$_\t", best_fit($_) for @ARGV;
