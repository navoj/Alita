#!/usr/pkg/bin/perl

use strict;
use warnings;
use Digest::SHA qw( sha256_hex );

my @symbols =  ('',' ','a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z','A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z','0','1','2','3','4','5','6','7','8','9','`','~','!','@','#','$','%','^','&','*');

my $MAXLEN = $#symbols;
my $input = '';
my $i;
my $j;
my $digest;
my $outputFile = "trainSHA256.txt";

open(OUTPUT, ">$outputFile") or die "Could not write to $outputFile: $!\n";

for ($i = 0; $i < $MAXLEN; $i++) {
	for ($j = 0; $j < $i; $j++) {
		$input = $input . $symbols[$j];
		$digest = sha256_hex($input);
		print OUTPUT "$input $digest\n";
	}
	$input = '';
}

