#!/usr/bin/env perl

# use strict;
use Config;
$Config{useithreads} or die('Recompile Perl with threads to run this program.');
use Storable;
use IO::Scalar;
use Term::ReadKey;

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
my $endTime;
my $randomThought;
my $brainSize;
my $waitTime = 60;
my $i;
my ($key, $value);

sub var_eval {
	local *FH;
	my $fh;
	tie (*FH, 'IO::Scalar', \$fh);
	$saved = select FH;
	eval shift;
	select $saved;
	$fh;
}

sub timed_input {
	my $end_time = time + shift;
	my $string;
	do {
		my $key = ReadKey(1);
		$string .= $key if defined $key;
	} while (time < $end_time);
	return $string;
};

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
	# An infinite strange loop that will eventually blossom into consciousness.
#	$input = <STDIN>;

	$input = timed_input($timedInput); 

 	if ($input eq "") {
		$randomThought = int(rand($brainSize));
		$i = 0;
		while (($key, $value) = each %memory) {
			if ($i == $randomThought) {
				print "Remember when you said: $key?\n";
			}
			$i += 1;
		}
	}					

	if ($input =~ /quit/i) {
		print "Saving my memories...\n";
	 	store \%memory, 'myBrain.dat';	
		exit 0;
	}

	if ($input =~ /simple\s*eval[\w]*/i) {
		print "Ok go ahead...\n";
		$response = <STDIN>;
		eval($response);
		if (!$@) { print "I think I got it.\n";
		} else {
			print "Uhhh...I don't get it!\n";
		}
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



