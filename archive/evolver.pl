#!/usr/pkg/bin/perl -w

use strict;

my $symbol_list = "symbols.dat";
my @symbol_pool = ();
my $element;   
my $index = 0;
my $embryo = "print ";
my $lifeform = "lifeform.pl";  
my $MAX_ITER = 2;  
my @genes = ();    
my $left_half = "";
my $right_half = "";  
my $line = "";  
my $code = "";  
my $i = 0;  
my $j = 0;   
my $evalreturn = ""; 
my $keypress;   

print "evolver.pl started\n";   

open(SYMBOLS, "<$symbol_list") or die "Could not open $symbol_list: $!\n";
open(LIFEFORM, ">$lifeform") or die "Could not create file $lifeform: $!\n";

# Load programming symbols into an array
while (<SYMBOLS>) {
	chomp $_;  
	print "\"$_\"\n";  
	push(@symbol_pool, $_);
}
close(SYMBOLS);   
$keypress = <STDIN>; 

$index = int(rand($#symbol_pool));
print "Initial embryo is:\n$embryo\n";   
$keypress = <STDIN>;
while (1) {
	$embryo = $embryo . $symbol_pool[$index];
#	print "$embryo\n";   
	$evalreturn = eval("$embryo");

	if (!$@ and ($evalreturn != "")) {
		print LIFEFORM "$embryo\n";
		print "\n\nA working program has been generated!\n";
		print "Line: $i\n\n"; 
		$i = $i + 1;   
	}   

	if (length($embryo) >= 80) {
#		print "embryo length >= 80\n";   
#		print "Continue?";
#		$keypress = <STDIN>;  
		@genes = split(//, $embryo);  
	        $index = int(rand(length($embryo)));
		while (length($embryo) >= 40) {
#			print "index is: $index\n";  
			if ($index < 2) {
				$index = $index + 2;
			}
			$right_half = "";

			for ($j = ($index + 1); $j <= length($embryo); $j++) {
				$right_half = $right_half . $genes[$j];
			}
#			print "left_half: $left_half\n";
#			print "right_half: $right_half\n";  
			$embryo = $right_half . $left_half;
			$index = int(rand(length($embryo)));  
#			printf("embryo length: %d\n", length($embryo) );  
#			print "Continue?";
#			$keypress = <STDIN>;  
		} # END WHILE 
#		print "embryo length has been cut to 39\n";   
	} # END IF

	$index = int(rand($#symbol_pool));  
	open(LIFEFORM, "<$lifeform");
	while ($line = <LIFEFORM>) {
		$code .= $line;
	}
	open(LIFEFORM, ">$lifeform");  
	eval($code);
	print "code: $code\n";
	$keypress = <STDIN>; 
	if ($i == $MAX_ITER and !$@) {
		print "Program Finished...\n";
		close(LIFEFORM);
		exit(0);
	}
} # END WHILE 

