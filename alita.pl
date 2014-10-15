#!/usr/bin/env perl

# use strict;
use Storable;
use IO::Scalar;

# This is an interactive learning program that builds a database
# by communicating with people and reading on the internet. 

my ($maxMem, %memory, $i);
my $input;
my $output;
my $response;
my $saved;
my $startTime;
my $endTime;

%memory = ();
if (-e 'myBrain.dat') {
	print "Hello my name is Alita.\n";
	%memory = %{retrieve('myBrain.dat')};
} else {
	print "Who am I?\n";
}
while (1) {
	$input = <STDIN>;
	if ($input =~ /quit/i) {
		print "Saving my memories...\n";
	 	store \%memory, 'myBrain.dat';	
		exit 0;
	}
	if ($input =~ /alitabraintweak/) {
		print("Enter new key-value pair:\n");
		print("Enter key: ");
		$input = <STDIN>;
		print("\nEnter value: ");
		$output = <STDIN>;
		$memory{$input} = $output;
	}
		
		
	if ($memory{$input}) {
		if ($#{$memory{$input}} > 0) {
			$output = var_eval($memory{$input}[0]);	
			$memory{'lastInput'} = [$input, $memory{$input}[1]];
			$memory{'lastOutput'} = $output;
#			sleep($memory{$input}[1] / 10);
			print $output;
			$output = $memory{$input}[1];
			print("Response time: $output\n");
		} else {
			$output = var_eval($memory{$input});
			$memory{'lastInput'} = $input;
			$memory{'lastOutput'} = $output;
			print $output;
		}
	} else {
		print "What? \n";
		print "Papa how should I respond to such input?\n";
	 	$startTime = time;		
		$response = <STDIN>;
		$endTime = time;
		$memory{$input} = [$response, $endTime - $startTime, ];
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
