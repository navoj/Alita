#!/usr/pkg/bin/perl 
# form_fit.pl
# Jovan Trujillo
# 4/22/2013
#
# This program fits a data set by randomly forming and testing functions.

my @X;
my @Y;
my $x;
my $y;

print "form_fit.pl Started...\n";

if ($#ARGV != 1) {
    print "form_fit.pl <data file>\n";
}

my $datafile = $ARGV[0];
open(MYDATA, "<$datafile") or die "Could not open file: $!\n";

# print "\$datafile = ", $datafile, "\n";
my $i = 0;
while (<MYDATA>) 
{
    ($X[$i], $Y[$i]) = split(/\t/);
    $i++;
}

my @ops = ("+","-","/","%","sin","cos","**",abs,exp,log,sqrt,C);
my $express = "\$x";

$index = int(rand($#ops));

# Calculate MSE of current test function
my $d;
my $MSE = 0;
for ($i=0; $i<=$#X; $i++) {
    $x = $X[$i];
    $y = eval($express);
    $d = sqrt(($y-$Y[$i])**2);
    $MSE = $MSE + $d;
}
$MSE = $MSE / $#X;

# Create new function
	
# print "Size of X = ", $#X, " and size of Y = ", $#Y, "\n";

close(MYDATA);

sub build_func() {
    # Vars:
    # \@ops, $expression, $index, \@X, \@Y
	my $ops = shift($_);
	my $expression = shift($_);
	my $index = shift($_);
	my $X = shift($_);
	my $Y = shift($_);
	
	my $newindex = int(rand($#ops));
	my @ops = @{$ops};

	if ($ops[$index] == "+") {
		$expression = $expression . "+" . build_func(\@ops,$expression,$newindex,\@X,\@Y);
	}
	if ($ops[$index] == "-") {
		$expression = $expression . "-" . build_func(\@ops,$expression,$newindex,\@X,\@Y);
	}	
	if ($ops[$index] == "*") {
		$expression = $expression . "*" . build_func(@ops,$expression,$newindex,\@X,\@Y);
	}
	if ($ops[$index] == "/") {
		$expression = $expression . "/" . build_func(@ops,$expression,$newindex,\@X,\@Y);
	}
	if ($ops[$index] == "/") {
		$expression = $expression . "%" . build_func(@ops,$expression,$newindex,\@X,\@Y);
	}
	if ($ops[$index] == "sin") {
		$expression = "sin(" . $expression . ")";
	}
	if ($ops[$index] == "cos") {
		$expression = "cos(" . $expression . ")";
	}
	if ($ops[$index] == "**") {
		$expression = $expression . "**" . build_func(@ops,$expression,$newindex,\@X,\@Y);
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
	    $tempexpress = $expression . "\$c";
	    $C = &fit_func($tempexpress, \@X, \@Y);
	    $expression = $expression . $C;
	}
}

sub fit_func() {
	# Find local minimum using test function and single constant.
	# Vars:
	# $expression, @X, @Y

	my $expression = shift($_);
	my $X = shift($_);
	my $Y = shift($_);

	my @X = @{$X};
	my @Y = @{$Y};
	my $stepsize = 0.0001;
	my @MSE; 	
	my $i;
	my @ex;
	my @ey;
	my $x = 0;

	for ($i=0; $i<=$#X; $i++) {
	    $ex[$i] = $X[$i];
	    $x = $ex[$i];
	    $ey[i] = eval($expression);
	}
}



