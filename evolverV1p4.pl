#!/usr/bin/perl

use strict;
use Storable;
use IO::Scalar;

# This is an interactive learning program that builds a database
# by communicating with people and reading on the internet. 

my ($maxMem, %memory, $i);
my $input;
my $output;
my $response;
my $lastResponse;
my $saved;
my $startTime;
my $elapsedTime;
my $randomThought;
my $brainSize;
my $waitTime = 60;
my $i;
my ($key, $value);

%memory = ();

if (-e 'myBrain.dat') {
	print "Hello my name is Alita.\n";
	%memory = %{retrieve('myBrain.dat')};
	$brainSize = keys %memory;
	
} else {
	print "Who am I?\n";
}
$startTime = time;
while (1) {
	$input = <STDIN>;
	if ($input =~ /quit/i) {
		print "Saving my memories...\n";
	 	store \%memory, 'myBrain.dat';	
		exit 0;
	}
	if ($input =~ /Let me teach you something[\w]*/i) {
		print "Ok go ahead...\n";
		$response = <STDIN>;
		eval($response);
		if (!$@) { print "I think I got it.\n"; 
		} else {
			 print "Uhhh...I don't get it!\n";
		 }
	}
	if ($memory{$input}) {
		$output = var_eval($memory{$input});	
		print $output;
		$lastResponse = $output;
	} else {
		print "What? \n";
		print "Papa how should I respond to such input?\n";
		$response = <STDIN>;
		$memory{$input} = $response;
		print "Oh ok.\n";
	}
	$elapsedTime = time - $startTime;
	if ($elapsedTime > $waitTime) {
		$randomThought = int(rand($brainSize));
		$i = 0;
		while (($key, $value) = each %memory) {
			if ($i == $randomThought) {
				print "Remember when you said: $key?\n";
			}
			$i = $i + 1;
		}
		$startTime = time;
	}
}

sub var_eval {
	local *FH;
	my $fh;
	tie (*FH, 'IO::Scalar', \$fh);
	$saved = select FH;
	eval shift;
	select $saved;
	$fh;
}
		
	
