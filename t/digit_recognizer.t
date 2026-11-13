use strict;
use warnings;
use Test::More;
use Cwd qw(abs_path);
use Digest::SHA ();
use File::Copy qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3 qw(open3);
use lib "$FindBin::RealBin/../lib";

use TinyLLM;

my $project_root = abs_path(File::Spec->catdir($FindBin::RealBin, '..'));
my $script = File::Spec->catfile($project_root, 'examples', 'digit_recognizer.pl');
ok(-f $script, 'digit-recognition example exists');

my $temporary_directory = tempdir(CLEANUP => 1);
my $run_number = 0;
my $train_path = File::Spec->catfile($temporary_directory, 'train.csv');
my $test_path = File::Spec->catfile($temporary_directory, 'test.csv');
my $model_path = File::Spec->catfile($temporary_directory, 'digits.dat');
my $output_path = File::Spec->catfile($temporary_directory, 'predictions.csv');

my $zero_pixels = join ',', (0) x 784;
my $active_pixels = join ',', (255) x 784;
my $pixel_header = join ',', map { "pixel$_" } 0 .. 783;

write_text(
    $train_path,
    join(
        "\n",
        "label,$pixel_header",
        "0,$zero_pixels",
        "1,$active_pixels",
        "0,$zero_pixels",
        "0,$zero_pixels",
        "1,$active_pixels",
        "1,$active_pixels",
    ) . "\n",
);
write_text(
    $test_path,
    join("\n", $pixel_header, $zero_pixels, $active_pixels) . "\n",
);

my ($status, $stdout, $stderr) = run_cli(
    'train',
    "--data=$train_path",
    "--model=$model_path",
    '--limit=6',
    '--validation=2',
);
is($status, 0, 'synthetic digit training succeeds') or diag $stderr;
ok(-s $model_path, 'training writes a nonempty model');
like($stdout, qr/Validation: 2\/2 correct/, 'training reports held-out accuracy');
is(
    TinyLLM->new(path => $model_path)->classifier_stats()->{threshold},
    128,
    'fresh CLI training uses the digit threshold default',
);

my $model_digest_before_evaluation = file_digest($model_path);
my $data_digest_before_evaluation = file_digest($train_path);
my $examples_before_evaluation = TinyLLM->new(
    path => $model_path,
)->classifier_stats()->{total_examples};
($status, $stdout, $stderr) = run_cli(
    'evaluate',
    "--data=$train_path",
    "--model=$model_path",
);
is($status, 0, 'evaluate scores labeled data') or diag $stderr;
like(
    $stdout,
    qr/^Overall:\s+evaluated=6,\s+correct=6,\s+accuracy=100\.00%$/m,
    'evaluate reports overall accuracy',
);
like(
    $stdout,
    qr/^Digit 0:\s+evaluated=3,\s+correct=3,\s+accuracy=100\.00%$/m,
    'evaluate reports accuracy for digit zero',
);
like(
    $stdout,
    qr/^Digit 1:\s+evaluated=3,\s+correct=3,\s+accuracy=100\.00%$/m,
    'evaluate reports accuracy for digit one',
);
is(
    file_digest($model_path),
    $model_digest_before_evaluation,
    'evaluate does not rewrite the model',
);
is(
    file_digest($train_path),
    $data_digest_before_evaluation,
    'evaluate does not rewrite labeled input data',
);
is(
    TinyLLM->new(path => $model_path)->classifier_stats()->{total_examples},
    $examples_before_evaluation,
    'evaluate does not train the classifier',
);

($status, $stdout, $stderr) = run_cli(
    'evaluate',
    "--data=$train_path",
    "--model=$model_path",
    '--limit=3',
);
is($status, 0, 'evaluate accepts a row limit') or diag $stderr;
like(
    $stdout,
    qr/^Overall:\s+evaluated=3,\s+correct=3,\s+accuracy=100\.00%$/m,
    'evaluate applies its row limit to the overall result',
);
like(
    $stdout,
    qr/^Digit 0:\s+evaluated=2,\s+correct=2,\s+accuracy=100\.00%$/m,
    'limited evaluation reports the observed zero rows',
);
like(
    $stdout,
    qr/^Digit 1:\s+evaluated=1,\s+correct=1,\s+accuracy=100\.00%$/m,
    'limited evaluation reports the observed one row',
);

($status, $stdout, $stderr) = run_cli(
    'predict',
    "--data=$test_path",
    "--model=$model_path",
    "--output=$output_path",
);
is($status, 0, 'synthetic prediction succeeds') or diag $stderr;
is(
    read_text($output_path),
    "ImageId,Label\n1,0\n2,1\n",
    'prediction writes the expected submission rows',
);

my $examples_before_resume = TinyLLM->new(
    path => $model_path,
)->classifier_stats()->{total_examples};
($status, $stdout, $stderr) = run_cli(
    'train',
    "--data=$train_path",
    "--model=$model_path",
    '--limit=2',
    '--validation=0',
    '--resume',
);
is($status, 0, 'resume adds genuinely selected rows') or diag $stderr;
is(
    TinyLLM->new(path => $model_path)->classifier_stats()->{total_examples},
    $examples_before_resume + 2,
    'resume persists additional examples',
);

my $custom_threshold_model = File::Spec->catfile(
    $temporary_directory,
    'custom-threshold.dat',
);
($status, $stdout, $stderr) = run_cli(
    'train',
    "--data=$train_path",
    "--model=$custom_threshold_model",
    '--limit=2',
    '--validation=0',
    '--threshold=200',
);
is($status, 0, 'training accepts a custom pixel threshold') or diag $stderr;
is(
    TinyLLM->new(path => $custom_threshold_model)->classifier_stats()->{threshold},
    200,
    'the custom threshold is stored in the model',
);
($status, $stdout, $stderr) = run_cli(
    'train',
    "--data=$train_path",
    "--model=$custom_threshold_model",
    '--limit=2',
    '--validation=0',
    '--resume',
);
is(
    $status,
    0,
    'resume inherits a stored custom threshold when the option is omitted',
) or diag $stderr;
my $custom_threshold_stats = TinyLLM->new(
    path => $custom_threshold_model,
)->classifier_stats();
is($custom_threshold_stats->{threshold}, 200, 'resume preserves the threshold');
is($custom_threshold_stats->{total_examples}, 4, 'resume adds the selected rows');

my $custom_threshold_digest = file_digest($custom_threshold_model);
($status, $stdout, $stderr) = run_cli(
    'train',
    "--data=$train_path",
    "--model=$custom_threshold_model",
    '--limit=2',
    '--validation=0',
    '--threshold=128',
    '--resume',
);
isnt($status, 0, 'resume rejects an explicitly mismatched threshold');
is(
    file_digest($custom_threshold_model),
    $custom_threshold_digest,
    'a threshold mismatch leaves the stored model unchanged',
);

for my $valid_threshold (0, 255) {
    my $boundary_model = File::Spec->catfile(
        $temporary_directory,
        "threshold-$valid_threshold.dat",
    );
    ($status, $stdout, $stderr) = run_cli(
        'train',
        "--data=$train_path",
        "--model=$boundary_model",
        '--limit=1',
        '--validation=0',
        "--threshold=$valid_threshold",
    );
    is($status, 0, "threshold $valid_threshold is accepted") or diag $stderr;
    is(
        TinyLLM->new(path => $boundary_model)->classifier_stats()->{threshold},
        $valid_threshold,
        "threshold $valid_threshold is persisted",
    );
}

my @invalid_thresholds = (
    ['negative', '-1'],
    ['above-range', '256'],
    ['not-a-number', 'NaN'],
    ['infinite', 'Inf'],
);
for my $case (@invalid_thresholds) {
    my ($name, $value) = @{$case};
    my $invalid_threshold_model = File::Spec->catfile(
        $temporary_directory,
        "invalid-threshold-$name.dat",
    );
    ($status, $stdout, $stderr) = run_cli(
        'train',
        "--data=$train_path",
        "--model=$invalid_threshold_model",
        '--limit=1',
        '--validation=0',
        "--threshold=$value",
    );
    isnt($status, 0, "threshold $value is rejected");
    ok(!-e $invalid_threshold_model, "threshold $value writes no model");
}

my $unexpected_train_model = File::Spec->catfile(
    $temporary_directory,
    'unexpected-train.dat',
);
($status, $stdout, $stderr) = run_cli(
    'train',
    "--data=$train_path",
    "--model=$unexpected_train_model",
    '--validation=0',
    'unexpected-positional-argument',
);
isnt($status, 0, 'train rejects unexpected positional arguments');
ok(!-e $unexpected_train_model, 'rejected train arguments write no model');

my $model_digest_before_rejected_evaluation = file_digest($model_path);
($status, $stdout, $stderr) = run_cli(
    'evaluate',
    "--data=$train_path",
    "--model=$model_path",
    'unexpected-positional-argument',
);
isnt($status, 0, 'evaluate rejects unexpected positional arguments');
is(
    file_digest($model_path),
    $model_digest_before_rejected_evaluation,
    'rejected evaluate arguments leave the model unchanged',
);

my $protected_model = File::Spec->catfile($temporary_directory, 'protected.dat');
copy($model_path, $protected_model) or die "Could not copy test model: $!";
my $model_digest_before = file_digest($protected_model);
my $bad_validation_path = File::Spec->catfile(
    $temporary_directory,
    'bad-validation.csv',
);
write_text(
    $bad_validation_path,
    join(
        "\n",
        "label,$pixel_header",
        "not-a-digit,$zero_pixels",
        "0,$zero_pixels",
        "1,$active_pixels",
    ) . "\n",
);
($status, $stdout, $stderr) = run_cli(
    'train',
    "--data=$bad_validation_path",
    "--model=$protected_model",
    '--validation=1',
    '--overwrite',
);
isnt($status, 0, 'malformed validation data fails training');
is(
    file_digest($protected_model),
    $model_digest_before,
    'failed validation does not replace an existing model',
);

my $bad_test_path = File::Spec->catfile($temporary_directory, 'bad-test.csv');
my $short_pixels = join ',', (0) x 783;
write_text(
    $bad_test_path,
    join("\n", $pixel_header, $zero_pixels, $short_pixels) . "\n",
);
write_text($output_path, "keep this output\n");
($status, $stdout, $stderr) = run_cli(
    'predict',
    "--data=$bad_test_path",
    "--model=$model_path",
    "--output=$output_path",
    '--overwrite',
);
isnt($status, 0, 'malformed prediction data fails');
is(
    read_text($output_path),
    "keep this output\n",
    'failed prediction does not replace an existing output',
);
my @temporary_outputs = glob File::Spec->catfile(
    $temporary_directory,
    'tinyllm-predictions-*',
);
is(scalar @temporary_outputs, 0, 'failed prediction removes its temporary file');

write_text($output_path, "keep positional output\n");
($status, $stdout, $stderr) = run_cli(
    'predict',
    "--data=$test_path",
    "--model=$model_path",
    "--output=$output_path",
    '--overwrite',
    'unexpected-positional-argument',
);
isnt($status, 0, 'predict rejects unexpected positional arguments');
is(
    read_text($output_path),
    "keep positional output\n",
    'rejected predict arguments leave an existing output unchanged',
);

my $invalid_label_model_path = File::Spec->catfile(
    $temporary_directory,
    'invalid-label.dat',
);
my $invalid_label_model = TinyLLM->new(
    path => $invalid_label_model_path,
    load => 0,
);
$invalid_label_model->train_example(
    label     => '10',
    features  => [(0) x 784],
    threshold => 128,
);
$invalid_label_model->save();
my $invalid_label_digest = file_digest($invalid_label_model_path);
($status, $stdout, $stderr) = run_cli(
    'evaluate',
    "--data=$train_path",
    "--model=$invalid_label_model_path",
);
isnt($status, 0, 'evaluate rejects model labels outside zero through nine');
like($stderr, qr/(?:label|digit).*10/i, 'evaluate identifies the invalid label');
is(
    file_digest($invalid_label_model_path),
    $invalid_label_digest,
    'invalid-label evaluation does not rewrite the model',
);

write_text($output_path, "keep invalid-label output\n");
($status, $stdout, $stderr) = run_cli(
    'predict',
    "--data=$test_path",
    "--model=$invalid_label_model_path",
    "--output=$output_path",
    '--overwrite',
);
isnt($status, 0, 'predict rejects model labels outside zero through nine');
like($stderr, qr/(?:label|digit).*10/i, 'predict identifies the invalid label');
is(
    read_text($output_path),
    "keep invalid-label output\n",
    'invalid-label prediction preserves an existing output',
);

my $metacharacter_directory = File::Spec->catdir(
    $temporary_directory,
    'path-%PATH%-$-`',
);
mkdir $metacharacter_directory
    or die "Could not create $metacharacter_directory: $!";
my $metacharacter_test = File::Spec->catfile(
    $metacharacter_directory,
    'test-%PATH%-$-`.csv',
);
my $metacharacter_model = File::Spec->catfile(
    $metacharacter_directory,
    'model-%PATH%-$-`.dat',
);
my $metacharacter_output = File::Spec->catfile(
    $metacharacter_directory,
    'output-%PATH%-$-`.csv',
);
copy($test_path, $metacharacter_test)
    or die "Could not copy metacharacter test data: $!";
copy($model_path, $metacharacter_model)
    or die "Could not copy metacharacter model: $!";
($status, $stdout, $stderr) = run_cli(
    'predict',
    "--data=$metacharacter_test",
    "--model=$metacharacter_model",
    "--output=$metacharacter_output",
);
is($status, 0, 'CLI paths may contain shell metacharacters') or diag $stderr;
is(
    read_text($metacharacter_output),
    "ImageId,Label\n1,0\n2,1\n",
    'metacharacter paths reach the CLI without shell interpolation',
);

done_testing();

sub run_cli {
    my (@arguments) = @_;
    $run_number++;
    my $stdout_path = File::Spec->catfile(
        $temporary_directory,
        "stdout-$run_number.txt",
    );
    my $stderr_path = File::Spec->catfile(
        $temporary_directory,
        "stderr-$run_number.txt",
    );
    open my $input, '<', File::Spec->devnull()
        or die "Could not open the null input device: $!";
    open my $stdout_file, '>', $stdout_path
        or die "Could not write $stdout_path: $!";
    open my $stderr_file, '>', $stderr_path
        or die "Could not write $stderr_path: $!";

    my $process_id = open3(
        ['&', $input],
        ['&', $stdout_file],
        ['&', $stderr_file],
        $^X,
        $script,
        @arguments,
    );
    waitpid $process_id, 0;
    my $exit_status = $? >> 8;
    close $input if defined fileno $input;
    close $stdout_file if defined fileno $stdout_file;
    close $stderr_file if defined fileno $stderr_file;
    return ($exit_status, read_text($stdout_path), read_text($stderr_path));
}

sub write_text {
    my ($path, $content) = @_;
    open my $file, '>', $path or die "Could not write $path: $!";
    print {$file} $content;
    close $file or die "Could not close $path: $!";
}

sub read_text {
    my ($path) = @_;
    open my $file, '<', $path or die "Could not read $path: $!";
    my $content = do { local $/; <$file> // '' };
    close $file;
    return $content;
}

sub file_digest {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "Could not read $path: $!";
    my $digest = Digest::SHA->new(256)->addfile($file)->hexdigest;
    close $file;
    return $digest;
}
