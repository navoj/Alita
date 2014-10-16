#!/usr/pkg/bin/perl
# test_scraps.pl
# Jovan Trujillo
# 4/23/2013
#
# This program tests out my understanding of pieces of the perl code I am writing to make
# sure I am understanding things correctly.

my @ops = ("+","-","/","%","sin","cos","**","abs","atan2","exp","log","sqrt","C");
my $express = "$x";
my $index = int(rand($#ops));

print "test_scraps.pl started...\n";
for ($i = 0; $i<=100; $i++) {
	print "\$express = ", $express, "\n";
	print "\$index = ", $index, "\n";
	print "\@ops[$index] = ", $ops[$index], "\n";	
 	$express = $express . $ops[$index];	
    	print "new \$express = ", $express, "\n";
	$index = int(rand($#ops));
}

# Create new function
sub build_func() {
    # Vars:
    # @ops, $expression, $index, $recurdepth 
	my @ops = shift(@_);
	my $expression = shift(@_);
	my $index = shift(@_);
	my $newindex = int(rand($#ops));
	my $recurdepth = shift(@_);
	print "build_func called at \$recurdepth = ", $recurdepth, "\n";
	print "newindex = ", $newindex, "\n";
	print "build_func made: ", $expression, "\n";
	if ($recurdepth >= 100) {
	die;	
	} else {
		$recurdepth++;
	}
	if ($ops[$index] == "+") {
		$expression = $expression . "+" . &build_func(@ops,$expression,$newindex, $recurdepth);
	}
	if ($ops[$index] == "-") {
		$expression = $expression . "-" . &build_func(@ops,$expression,$newindex, $recurdepth);
	}	
	if ($ops[$index] == "*") {
		$expression = $expression . "*" . &build_func(@ops,$expression,$newindex, $recurdepth);
	}
	if ($ops[$index] == "/") {
		$expression = $expression . "/" . &build_func(@ops,$expression,$newindex, $recurdepth);
	}
	if ($ops[$index] == "/") {
		$expression = $expression . "%" . &build_func(@ops,$expression,$newindex, $recurdepth);
	}
	if ($ops[$index] == "sin") {
		$expression = "sin(" . $expression . ")";
	}
	if ($ops[$index] == "cos") {
		$expression = "cos(" . $expression . ")";
	}
	if ($ops[$index] == "**") {
		$expression = $expression . "**" . &build_func(@ops,$expression,$newindex, $recurdepth);
	}
	if ($ops[$index] == "abs") {
		$expression = "abs(" . $expression . ")";
	}
	if ($ops[$index] == "atan2") {
		$expression = "atan2(" . $expression . ")";
	}
	if ($ops[$index] == "exp") {
		$expression = "exp(" . $expression . ")";
	}
	if ($ops[$index] == "log") {
		$expression = "log(" . $expression . ")";
	}
	if ($ops[$index] == "sqrt") {
		$expression = "sqrt(" . $expression . ")";
	}
	if ($ops[$index] == "C") {
	    $expression = $expression . "$C";
	    return $expression;
	}
}
