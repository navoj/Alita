#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use Getopt::Long qw(GetOptions);
use POSIX qw(isfinite);
use Scalar::Util qw(looks_like_number);
use TinyLLM;

my $project_root = File::Spec->rel2abs(
    File::Spec->catdir($FindBin::RealBin, File::Spec->updir()),
);

my $command = shift(@ARGV) // '';
if ($command eq 'train') {
    train_command();
} elsif ($command eq 'predict') {
    predict_command();
} elsif ($command eq 'evaluate') {
    evaluate_command();
} elsif ($command eq 'help' || $command eq '--help' || $command eq '-h') {
    usage(0);
} else {
    warn "Unknown or missing command '$command'.\n" if length $command;
    usage(2);
}

sub train_command {
    my %options = (
        data       => File::Spec->catfile($project_root, 'digit-recognizer', 'train.csv'),
        model      => File::Spec->catfile($FindBin::RealBin, 'tinyllm-digits.dat'),
        limit      => 0,
        validation => 2_000,
        threshold  => undef,
        resume     => 0,
        overwrite  => 0,
        help       => 0,
    );

    GetOptions(
        'data=s'       => \$options{data},
        'model=s'      => \$options{model},
        'limit=i'      => \$options{limit},
        'validation=i' => \$options{validation},
        'threshold=f'  => \$options{threshold},
        'resume!'      => \$options{resume},
        'overwrite!'   => \$options{overwrite},
        'help|h'       => \$options{help},
    ) or usage(2);
    reject_positional_arguments('train');
    usage(0) if $options{help};

    die "--limit must be zero or a positive integer\n" if $options{limit} < 0;
    die "--validation must be zero or a positive integer\n"
        if $options{validation} < 0;
    die "--limit must be greater than --validation\n"
        if $options{limit} && $options{limit} <= $options{validation};
    die "Use either --resume or --overwrite, not both\n"
        if $options{resume} && $options{overwrite};
    my $threshold_was_explicit = defined $options{threshold};
    if ($threshold_was_explicit) {
        $options{threshold} = validate_threshold($options{threshold}, '--threshold');
    }
    die "Training data not found: $options{data}\n" if !-f $options{data};
    die "The model path must be different from the training-data path\n"
        if same_path($options{model}, $options{data});

    if (-e $options{model}) {
        die "Model already exists: $options{model}\n"
            . "Use --resume to add examples or --overwrite to start over.\n"
            if !$options{resume} && !$options{overwrite};
    } elsif ($options{resume}) {
        die "Cannot resume because the model does not exist: $options{model}\n";
    }

    my $model = TinyLLM->new(
        path => $options{model},
        load => $options{resume} ? 1 : 0,
    );
    my $before = $model->classifier_stats();
    if ($options{resume}) {
        $before = validate_digit_model($model, $options{model});
        my $saved_threshold = $before->{threshold};
        if ($threshold_was_explicit && $options{threshold} != $saved_threshold) {
            die "--threshold $options{threshold} conflicts with the saved model's "
                . "threshold $saved_threshold; omit --threshold to inherit it\n";
        }
        $options{threshold} = $saved_threshold if !$threshold_was_explicit;
    } else {
        $options{threshold} = 128 if !$threshold_was_explicit;
    }
    my $before_count = $before ? $before->{total_examples} : 0;

    open my $input, '<', $options{data}
        or die "Cannot read $options{data}: $!\n";
    validate_header($input, 1, $options{data});

    my ($rows_seen, $trained) = (0, 0);
    while (my $line = <$input>) {
        $rows_seen++;
        last if $options{limit} && $rows_seen > $options{limit};
        next if $rows_seen <= $options{validation};

        my ($label, $pixels) = parse_labeled_row($line, $rows_seen + 1, $options{data});
        $model->train_example(
            label     => $label,
            features  => $pixels,
            threshold => $options{threshold},
        );
        $trained++;
        print "Trained $trained rows...\n" if $trained % 5_000 == 0;
    }
    close $input or die "Cannot close $options{data}: $!\n";
    die "No training rows were available after the validation holdout\n"
        if !$trained;

    my $stats = $model->classifier_stats();
    my $evaluation = $options{validation}
        ? evaluate_labeled_data(
            $model,
            data  => $options{data},
            limit => $options{validation},
        )
        : undef;

    # Do not replace an existing model until both training and validation have
    # completed successfully.
    $model->save();
    my $model_size = -s $options{model};
    print "Added $trained labeled images ($before_count -> $stats->{total_examples}).\n";
    printf "Saved model to %s (%d bytes, %.2f KiB)\n",
        $options{model}, $model_size, $model_size / 1024;
    if ($evaluation) {
        print_evaluation_summary('Validation', $evaluation, 0);
    }
}

sub evaluate_command {
    my %options = (
        data  => File::Spec->catfile($project_root, 'digit-recognizer', 'train.csv'),
        model => File::Spec->catfile($FindBin::RealBin, 'tinyllm-digits.dat'),
        limit => 0,
        help  => 0,
    );

    GetOptions(
        'data=s'  => \$options{data},
        'model=s' => \$options{model},
        'limit=i' => \$options{limit},
        'help|h'  => \$options{help},
    ) or usage(2);
    reject_positional_arguments('evaluate');
    usage(0) if $options{help};

    die "--limit must be zero or a positive integer\n" if $options{limit} < 0;
    die "Evaluation data not found: $options{data}\n" if !-f $options{data};
    die "Model not found: $options{model}\n" if !-f $options{model};

    my $model = TinyLLM->new(path => $options{model});
    validate_digit_model($model, $options{model});
    my $evaluation = evaluate_labeled_data(
        $model,
        data  => $options{data},
        limit => $options{limit},
    );

    print "Evaluation is read-only: the model was not trained or saved.\n";
    print "For a meaningful held-out score, the labeled data must be unseen "
        . "during training.\n";
    print_evaluation_summary('Evaluation', $evaluation, 1);
}

sub evaluate_labeled_data {
    my ($model, %args) = @_;
    my $data = $args{data};
    my $limit = $args{limit} // 0;
    open my $input, '<', $data
        or die "Cannot read $data: $!\n";
    validate_header($input, 1, $data);

    my ($evaluated, $correct) = (0, 0);
    my %per_digit = map { $_ => { evaluated => 0, correct => 0 } } 0 .. 9;
    while (my $line = <$input>) {
        last if $limit && $evaluated >= $limit;
        my ($label, $pixels) = parse_labeled_row(
            $line,
            $evaluated + 2,
            $data,
        );
        my $result = $model->predict(features => $pixels);
        my $is_correct = $result->{label} eq $label;
        $correct++ if $is_correct;
        $per_digit{$label}{evaluated}++;
        $per_digit{$label}{correct}++ if $is_correct;
        $evaluated++;
    }
    close $input or die "Cannot close $data: $!\n";
    die "No labeled rows were found for evaluation in $data\n" if !$evaluated;

    return {
        correct   => $correct,
        evaluated => $evaluated,
        per_digit => \%per_digit,
    };
}

sub print_evaluation_summary {
    my ($name, $evaluation, $include_per_digit) = @_;
    if ($include_per_digit) {
        printf "Overall: evaluated=%d, correct=%d, accuracy=%.2f%%\n",
            $evaluation->{evaluated},
            $evaluation->{correct},
            100 * $evaluation->{correct} / $evaluation->{evaluated};
    } else {
        printf "%s: %d/%d correct (%.2f%% accuracy).\n",
            $name,
            $evaluation->{correct},
            $evaluation->{evaluated},
            100 * $evaluation->{correct} / $evaluation->{evaluated};
    }
    return if !$include_per_digit;

    for my $digit (0 .. 9) {
        my $counts = $evaluation->{per_digit}{$digit};
        if ($counts->{evaluated}) {
            printf "Digit %d: evaluated=%d, correct=%d, accuracy=%.2f%%\n",
                $digit,
                $counts->{evaluated},
                $counts->{correct},
                100 * $counts->{correct} / $counts->{evaluated};
        } else {
            printf "Digit %d: evaluated=0, correct=0, accuracy=n/a\n", $digit;
        }
    }
}

sub predict_command {
    my %options = (
        data      => File::Spec->catfile($project_root, 'digit-recognizer', 'test.csv'),
        model     => File::Spec->catfile($FindBin::RealBin, 'tinyllm-digits.dat'),
        output    => File::Spec->catfile($FindBin::RealBin, 'digit-submission.csv'),
        limit     => 0,
        overwrite => 0,
        help      => 0,
    );

    GetOptions(
        'data=s'     => \$options{data},
        'model=s'    => \$options{model},
        'output=s'   => \$options{output},
        'limit=i'    => \$options{limit},
        'overwrite!' => \$options{overwrite},
        'help|h'     => \$options{help},
    ) or usage(2);
    reject_positional_arguments('predict');
    usage(0) if $options{help};

    die "--limit must be zero or a positive integer\n" if $options{limit} < 0;
    die "Test data not found: $options{data}\n" if !-f $options{data};
    die "Model not found: $options{model}\n" if !-f $options{model};
    die "The output path must differ from the data and model paths\n"
        if same_path($options{output}, $options{data})
        || same_path($options{output}, $options{model});
    die "Output already exists: $options{output}\nUse --overwrite to replace it.\n"
        if -e $options{output} && !$options{overwrite};
    die "Output path is a directory: $options{output}\n"
        if -d $options{output};

    my $model = TinyLLM->new(path => $options{model});
    validate_digit_model($model, $options{model});

    open my $input, '<', $options{data}
        or die "Cannot read $options{data}: $!\n";
    validate_header($input, 0, $options{data});

    my $output_directory = dirname(File::Spec->rel2abs($options{output}));
    make_path($output_directory) if !-d $output_directory;
    my ($output, $temporary_output) = tempfile(
        'tinyllm-predictions-XXXXXX',
        DIR    => $output_directory,
        UNLINK => 0,
    );

    my $image_id = 0;
    my $write_succeeded = eval {
        print {$output} "ImageId,Label\n"
            or die "Cannot write $temporary_output: $!\n";
        while (my $line = <$input>) {
            last if $options{limit} && $image_id >= $options{limit};
            $image_id++;
            my $pixels = parse_unlabeled_row($line, $image_id + 1, $options{data});
            my $result = $model->predict(features => $pixels);
            print {$output} "$image_id,$result->{label}\n"
                or die "Cannot write $temporary_output: $!\n";
            print "Predicted $image_id rows...\n" if $image_id % 5_000 == 0;
        }
        close $input or die "Cannot close $options{data}: $!\n";
        close $output or die "Cannot close $temporary_output: $!\n";
        1;
    };
    if (!$write_succeeded) {
        my $error = $@ || 'Unknown prediction error';
        close $input;
        close $output;
        unlink $temporary_output;
        die $error;
    }

    rename $temporary_output, $options{output}
        or die "Cannot move $temporary_output to $options{output}: $!\n";
    print "Wrote $image_id predictions to $options{output}\n";
}

sub validate_digit_model {
    my ($model, $path) = @_;
    my $stats = $model->classifier_stats();
    die "The model has no trained classifier: $path\n"
        if !$stats || !$stats->{total_examples};
    die "Digit models must contain 784 features; this model has $stats->{feature_count}\n"
        if $stats->{feature_count} != 784;
    validate_threshold($stats->{threshold}, "The model's threshold");

    my @unexpected_labels = grep { !/\A[0-9]\z/ }
        keys %{$stats->{examples_by_label}};
    if (@unexpected_labels) {
        my $labels = join ', ', map { "'$_'" } sort @unexpected_labels;
        die "Digit models may only contain labels 0 through 9; found $labels in $path\n";
    }
    return $stats;
}

sub validate_threshold {
    my ($value, $name) = @_;
    die "$name must be a finite number from 0 through 255\n"
        if !defined($value) || !looks_like_number($value)
        || !isfinite(0 + $value) || $value < 0 || $value > 255;
    return 0 + $value;
}

sub reject_positional_arguments {
    my ($command_name) = @_;
    return if !@ARGV;
    my $arguments = join ' ', map { "'$_'" } @ARGV;
    die "Unexpected argument(s) for $command_name: $arguments\n";
}

sub validate_header {
    my ($input, $has_label, $path) = @_;
    my $header = <$input>;
    die "CSV file is empty: $path\n" if !defined $header;
    $header =~ s/\r?\n\z//;
    my @columns = split /,/, $header, -1;

    if ($has_label) {
        my $label_column = shift @columns;
        die "Expected the first column in $path to be 'label'\n"
            if !defined($label_column) || $label_column ne 'label';
    }

    die sprintf("Expected 784 pixel columns in %s but found %d\n", $path, scalar @columns)
        if @columns != 784;
    for my $i (0 .. 783) {
        die "Expected column pixel$i in $path, found '$columns[$i]'\n"
            if $columns[$i] ne "pixel$i";
    }
}

sub parse_labeled_row {
    my ($line, $line_number, $path) = @_;
    my $values = parse_values($line, 785, $line_number, $path);
    my $label = shift @{$values};
    die "Invalid digit label '$label' at $path line $line_number\n"
        if $label !~ /\A[0-9]\z/;
    validate_pixels($values, $line_number, $path);
    return ($label, $values);
}

sub parse_unlabeled_row {
    my ($line, $line_number, $path) = @_;
    my $values = parse_values($line, 784, $line_number, $path);
    validate_pixels($values, $line_number, $path);
    return $values;
}

sub parse_values {
    my ($line, $expected, $line_number, $path) = @_;
    $line =~ s/\r?\n\z//;
    my @values = split /,/, $line, -1;
    die sprintf(
        "Expected %d values at %s line %d but found %d\n",
        $expected, $path, $line_number, scalar @values,
    ) if @values != $expected;
    return \@values;
}

sub validate_pixels {
    my ($pixels, $line_number, $path) = @_;
    for my $i (0 .. $#{$pixels}) {
        my $value = $pixels->[$i];
        die "Invalid pixel$i value '$value' at $path line $line_number\n"
            if !looks_like_number($value) || !isfinite(0 + $value)
            || $value < 0 || $value > 255;
    }
}

sub same_path {
    my ($left, $right) = @_;
    my $left_absolute = File::Spec->canonpath(File::Spec->rel2abs($left));
    my $right_absolute = File::Spec->canonpath(File::Spec->rel2abs($right));
    my $same_name = File::Spec->case_tolerant()
        ? lc($left_absolute) eq lc($right_absolute)
        : $left_absolute eq $right_absolute;
    return 1 if $same_name;

    # Different names can still refer to one file through a hard link or
    # symbolic link. Compare filesystem identity before allowing an overwrite.
    if (-e $left && -e $right) {
        my @left_stat = stat $left;
        my @right_stat = stat $right;
        return 1 if @left_stat && @right_stat
            && $left_stat[0] == $right_stat[0]
            && $left_stat[1] == $right_stat[1];
    }
    return 0;
}

sub usage {
    my ($exit_code) = @_;
    print <<'USAGE';
Train and use TinyLLM's digit classifier.

Usage:
  perl examples/digit_recognizer.pl train [options]
  perl examples/digit_recognizer.pl predict [options]
  perl examples/digit_recognizer.pl evaluate [options]

Train options:
  --data=PATH          Labeled CSV (default: digit-recognizer/train.csv)
  --model=PATH         Saved model (default: examples/tinyllm-digits.dat)
  --limit=N            Consider only N rows; 0 means all rows (default: 0)
  --validation=N       Reserve the first N rows for evaluation (default: 2000)
  --threshold=N        Pixel threshold, 0..255 (new-model default: 128)
  --resume             Add the CSV's training rows to an existing model
  --overwrite          Start a fresh model even if the path already exists

Predict options:
  --data=PATH          Unlabeled CSV (default: digit-recognizer/test.csv)
  --model=PATH         Trained model (default: examples/tinyllm-digits.dat)
  --output=PATH        ImageId,Label CSV (default: examples/digit-submission.csv)
  --limit=N            Predict only N rows; 0 means all rows (default: 0)
  --overwrite          Replace an existing output CSV

Evaluate options (read-only):
  --data=PATH          Labeled CSV (default: digit-recognizer/train.csv)
  --model=PATH         Trained model (default: examples/tinyllm-digits.dat)
  --limit=N            Evaluate only N rows; 0 means all rows (default: 0)

Use --resume only for genuinely new labeled rows; replaying the same rows counts
them again. With --resume, omit --threshold to inherit the saved threshold. Use
--validation=0 when every labeled row should train the model.

Evaluation does not train or save. For a meaningful held-out score, evaluate a
labeled CSV whose rows were not used to train the model.

Prediction, evaluation, and --resume require a 784-feature classifier whose
labels are digits from 0 through 9.
USAGE
    exit $exit_code;
}
