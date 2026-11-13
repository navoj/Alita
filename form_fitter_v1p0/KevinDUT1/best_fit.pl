#!/usr/bin/env perl
# Function evolved by form_fit.pl from .\KevinDUT1.txt
#   y = 38.460981 - 53.459596 * sqrt((sin(log(log(log(x)))) + (exp(log(x)) / x))) + 0.0072420788 * log((2.09331e+06 / x)) + 0.057754053 * log(sin((0.0618037 / x))) + 1.5687513 * log(log(x)) - 0.0059285389 * log((exp(log(x)) + x)) + 30.304282 * (exp(log(x)) / x)
# Usage: perl best_fit.pl x1 x2 ...
use v5.36;
no warnings;

sub pdiv($l, $r) { abs($r) < 1e-12 ? 1 : $l / $r }
sub plog($v)     { $v == 0 ? 0 : log(abs $v) }
sub pexp($v)     { exp($v > 100 ? 100 : $v) }
sub psqrt($v)    { sqrt(abs $v) }

sub best_fit($x) { return 38.460981251284309 - 53.459595528583783 * main::psqrt((sin(main::plog(main::plog(main::plog($x)))) + main::pdiv(main::pexp(main::plog($x)), $x))) + 0.0072420788105533171 * main::plog(main::pdiv(2093306.4849720334, $x)) + 0.057754052733439407 * main::plog(sin(main::pdiv(0.061803657187680543, $x))) + 1.5687512829625077 * main::plog(main::plog($x)) - 0.0059285388793274031 * main::plog((main::pexp(main::plog($x)) + $x)) + 30.304281726175457 * main::pdiv(main::pexp(main::plog($x)), $x) }

say "$_\t", best_fit($_) for @ARGV;
