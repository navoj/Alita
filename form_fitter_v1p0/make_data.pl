#!/usr/pkg/bin/perl -w

open(DATA, ">", "data.txt") or die "Could not open $!\n";

my $i;
my $x;
my $y;

for ($i=0; $i<100; $i++) {
    $x = $i;
    $y = sin($x);

    print DATA $x, "\t", $y, "\n";
}
