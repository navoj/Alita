#!/usr/pkg/bin/perl
# test_scraps.pl
# Jovan Trujillo
# 4/23/2013
#
# This program tests out my understanding of pieces of the perl code I am writing to make
# sure I am understanding things correctly.

my @ops = ("+","-","/","%","sin","cos","**","abs","exp","log","sqrt","C");
my $express = "\$x";
my $index = int(rand($#ops));
my $x = 1.2;
my $C = 100;
print "test_scraps.pl started...\n";
for ($i = 0; $i<=100; $i++) {
	#print "express = ", $express, "\n";
	#print "index = ", $index, "\n";
	#print "ops[$index] = ", $ops[$index], "\n";	
	do {
	$express = "\$x";
    	$express = &build_func(\@ops, $express, $index, 0);
	} while (eval($express) == NULL);
    	print "expression = ", $express, "\n";
	$express = "\$x";
	$index = int(rand($#ops));
}

# Create new function
sub build_func() {
    # Vars:
    # @ops, $expression, $index, $recurdepth 
	my ($myops, $expression, $index, $recurdepth) = @_;
	my @myops = @{$myops};
	#print "expression = ", $expression, "\n";
	#print "myops[$index] = ", $myops[$index], "\n";
	#print "recurdepth = ", $recurdepth, "\n";
	if ($recurdepth == 100) {
	exit 0;
	}
	$recurdepth++;

	if ($myops[$index] eq "+") {
		$expression = $expression . "+" . build_func(\@myops,$expression,int(rand($#myops)), $recurdepth);
	}
	if ($myops[$index] eq "-") {
		$expression = $expression . "-" . build_func(\@myops,$expression,int(rand($#myops)), $recurdepth);
	}	
	if ($myops[$index] eq "*") {
		$expression = $expression . "*" . build_func(\@myops,$expression,int(rand($#myops)), $recurdepth);
	}
	if ($myops[$index] eq "/") {
		$expression = $expression . "/" . build_func(\@myops,$expression,int(rand($#myops)), $recurdepth);
	}
	if ($myops[$index] eq "/") {
		$expression = $expression . "%" . build_func(\@myops,$expression,int(rand($#myops)), $recurdepth);
	}
	if ($myops[$index] eq "sin") {
		$expression = "sin(" . $expression . ")";
	}
	if ($myops[$index] eq "cos") {
		$expression = "cos(" . $expression . ")";
	}
	if ($myops[$index] eq "**") {
		$expression = $expression . "**" . build_func(\@myops,$expression,int(rand($#myops)), $recurdepth);
	}
	if ($myops[$index] eq "abs") {
		$expression = "abs(" . $expression . ")";
	}
	if ($myops[$index] eq "atan2") {
		$expression = "atan2(" . $expression . ")";
	}
	if ($myops[$index] eq "exp") {
		$expression = "exp(" . $expression . ")";
	}
	if ($myops[$index] eq "log") {
		$expression = "log(" . $expression . ")";
	}
	if ($myops[$index] eq "sqrt") {
		$expression = "sqrt(" . $expression . ")";
	}
	if ($myops[$index] eq "C") {
	    $expression = $expression . "\$C";
	}
	#print "new expression = ", $expression, "\n";
	return $expression;
}
