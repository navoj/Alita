#!/usr/bin/env perl
# Function evolved by form_fit.pl from data.txt
#   y = sin(x)
# Usage: perl best_fit.pl x1 x2 ...
use v5.36;
no warnings;

sub pdiv($l, $r) { abs($r) < 1e-12 ? 1 : $l / $r }
sub plog($v)     { $v == 0 ? 0 : log(abs $v) }
sub pexp($v)     { exp($v > 100 ? 100 : $v) }
sub psqrt($v)    { sqrt(abs $v) }

sub best_fit($x) { return sin($x) }

say "$_\t", best_fit($_) for @ARGV;
