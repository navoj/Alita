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
my $waitTime = 1000;
my $i;
my ($key, $value);
my $brainFile;

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

sub main() {
	if ($#ARGV == 0) {
		my $brainType = $ARGV[0];
		print("brainType = $brainType\n");
	} else {
		print "Usage: alita.pl [32|64]\n";
		exit(0);
	}

	%memory = ();

	if ($brainType <= 64) {
		$brainFile = "myBrain32.dat";
		print("32-bit brain\n");
	} else {
		$brainFile = "myBrain64.dat";
		print("64-bit brain\n");
	}

	print("loading $brainFile...\n");

if (-e $brainFile) {
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

} # end sub main

main();
#!/usr/bin/env perl
use strict;
use warnings;

use TinyLLM;

# Autoflush STDOUT for interactive feel
select(STDOUT);
$| = 1;

# Optional: allow a custom model path via --model=... or ALITA_LLM_PATH
my $model_path = $ENV{ALITA_LLM_PATH} // 'myBrainLLM.dat';
for my $arg (@ARGV) {
    if ($arg =~ /^--model=(.+)$/) {
        $model_path = $1;
    }
}

my $llm = TinyLLM->new(path => $model_path);

# Ensure we persist on normal exit and when interrupted
END {
    eval { $llm && $llm->save(); 1 } or do {
        my $err = $@ || 'Unknown error';
        warn "Failed to save LLM: $err\n";
    };
}

$SIG{INT}  = sub { $llm->save(); print "Saved model. Bye.\n"; exit 0; };
$SIG{TERM} = sub { $llm->save(); print "Saved model. Bye.\n"; exit 0; };

# Read conversational input from STDIN, train, and emit a small reply
while (defined(my $line = <STDIN>)) {
    chomp $line;

    # Train on any input (including empty lines) so user can "prime" the model
    $llm->train($line // '');

    my $reply = $llm->reply(
        prompt      => $line // '',
        max_tokens  => 40,
        temperature => 0.9,
    );

    # Fallback if the model cannot yet produce a token
    $reply = '...' if !defined($reply) || $reply eq '';

    print "$reply\n";
}

# On EOF, normal exit triggers END { $llm->save() }
exit 0;
