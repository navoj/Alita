#!/usr/pkg/bin/perl
use strict;
use warnings;
use Digest::SHA qw( sha256_hex );
my $phrase = "Rosetta code";
my $digest = sha256_hex($phrase);
# my $phrase = "Rosetta code";
print "SHA-256('$phrase'): $digest\n";



