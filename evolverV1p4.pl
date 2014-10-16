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
my $saved;

%memory = ();
print "Hello my name is Alita.\n";
if (-e 'myBrain.dat') {
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
	if ($memory{$input}) {
		$output = var_eval($memory{$input});	
		print $output;
	} else {
		print "What? \n";
		print "Papa how should I respond to such input?\n";
		$response = <STDIN>;
		$memory{$input} = $response;
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
		
	
