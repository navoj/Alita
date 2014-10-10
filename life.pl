#!/usr/bin/env perl
use strict;

my @data = ();
my $size = @data;
my $brainSize = 500000;
my ($average, $variance, $sum, $min, $max);
my $food = rand();

my $lifetime = 1000000;

my $i;
$sum = 0;
for ($i = 0; $i <= $lifetime; $i++) {
	if ($food > 0.5) {
		push(@data, $food);
		$size= @data;
		$sum += $food;
	}
	
	if ($size > $brainSize) {
		pop(@data);
	}
	
	$food = rand();
}
$average = $sum / $size;
$max = 0;
$min = 1;
for ($i = 0; $i < $size; $i++) {
	$variance = ($data[$i] - $average)**2;
	if ($data[$i] > $max) {
		$max = $data[$i];
	}
	if ($data[$i] < $min) {
		$min = $data[$i];
	}
}
$variance /= $size;

print "Lifeform is finished.\n";
print "Lifeform size is $size.\n";
print "Lifeform sum is $sum.\n";
print "Lifeform max is $max.\n";
print "Lifeform min is $min.\n";
print "Lifeform average is $average\n";
print "Lifeform variance is $variance\n";
	
