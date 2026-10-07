use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Storable qw(nstore retrieve);
use lib "$FindBin::RealBin/../lib";

use TinyLLM;

my $temporary_directory = tempdir(CLEANUP => 1);
my $model_path = File::Spec->catfile($temporary_directory, 'classifier.dat');
my $model = TinyLLM->new(path => $model_path, load => 0);

ok(!defined($model->classifier_stats()), 'a fresh model has no classifier');

for (1 .. 5) {
    $model->train_example(
        label     => 'dark',
        features  => [0, 0, 0, 0],
        threshold => 128,
    );
    $model->train_example(
        label     => 'bright',
        features  => [255, 255, 255, 255],
        threshold => 128,
    );
}

my $stats = $model->classifier_stats();
is(
    $stats->{algorithm},
    'bernoulli_naive_bayes',
    'classifier stats identify the classification algorithm',
);
is($stats->{feature_count}, 4, 'classifier records its feature count');
is($stats->{threshold}, 128, 'classifier records its threshold');
is($stats->{total_examples}, 10, 'classifier counts training examples');
is($stats->{label_count}, 2, 'classifier stats count distinct labels');
is(
    $stats->{stored_feature_counts},
    8,
    'classifier stats report the number of stored feature counts',
);
is_deeply(
    $stats->{examples_by_label},
    { bright => 5, dark => 5 },
    'classifier reports examples by label',
);

my $dark = $model->predict(features => [0, 10, 20, 30]);
is($dark->{label}, 'dark', 'predicts an inactive feature vector');
cmp_ok($dark->{confidence}, '>', 0.5, 'prediction includes a useful confidence');

my $bright = $model->predict(features => [200, 210, 220, 230]);
is($bright->{label}, 'bright', 'predicts an active feature vector');
is(
    $model->predict(features => [200, 210, 220, 230], alpha => 1e-20)->{label},
    'bright',
    'very small smoothing values remain numerically stable',
);
is(
    $model->predict(features => [200, 210, 220, 230], alpha => 1e308)->{label},
    'bright',
    'very large smoothing values remain numerically stable',
);

my $probability_sum = 0;
$probability_sum += $_ for values %{$bright->{probabilities}};
cmp_ok(abs($probability_sum - 1), '<', 1e-9, 'prediction probabilities are normalized');

my $confidence_before_invalid_example = $bright->{confidence};
my $invalid_error = '';
eval {
    $model->train_example(
        label     => 'bright',
        features  => [255, 255, 'not-a-number', 255],
        threshold => 128,
    );
    1;
} or $invalid_error = $@;
like($invalid_error, qr/not a finite number/, 'malformed features are rejected');
my $confidence_after_invalid_example = $model->predict(
    features => [200, 210, 220, 230],
)->{confidence};
cmp_ok(
    abs($confidence_after_invalid_example - $confidence_before_invalid_example),
    '<',
    1e-12,
    'a rejected example does not partially update the classifier',
);

$model->train('small text model');
$model->save();
ok(-s $model_path, 'save writes a nonempty model file');

my $reloaded = TinyLLM->new(path => $model_path);
is(
    $reloaded->predict(features => [255, 255, 255, 255])->{label},
    'bright',
    'classifier survives save and reload',
);

my $copied_path = File::Spec->catfile($temporary_directory, 'copied.dat');
copy($model_path, $copied_path) or die "Could not copy test model: $!";
my $copied_model = TinyLLM->new(path => $copied_path);
$copied_model->train_example(
    label     => 'bright',
    features  => [255, 255, 255, 255],
    threshold => 128,
);
$copied_model->save();
is(
    TinyLLM->new(path => $copied_path)->classifier_stats()->{total_examples},
    11,
    'a copied model saves to the constructor path',
);
is(
    TinyLLM->new(path => $model_path)->classifier_stats()->{total_examples},
    10,
    'saving a copied model does not modify its original path',
);

my $fresh = TinyLLM->new(path => $model_path, load => 0);
ok(!defined($fresh->classifier_stats()), 'load => 0 starts over at an existing path');

my $error = '';
eval { $reloaded->predict(features => [1, 2, 3]); 1 } or $error = $@;
like($error, qr/feature count mismatch/, 'predict rejects the wrong feature count');

$error = '';
eval {
    $reloaded->train_example(
        label     => 'bright',
        features  => [255, 255, 255, 255],
        threshold => 64,
    );
    1;
} or $error = $@;
like($error, qr/threshold mismatch/, 'incremental training preserves preprocessing');

my $default_threshold_model = TinyLLM->new(
    path => File::Spec->catfile($temporary_directory, 'default-threshold.dat'),
    load => 0,
);
$default_threshold_model->train_example(label => 'binary', features => [0, 1]);
is(
    $default_threshold_model->classifier_stats()->{threshold},
    0.5,
    'the default threshold handles binary zero/one features',
);

my $inherited_threshold_model = TinyLLM->new(
    path => File::Spec->catfile($temporary_directory, 'inherited-threshold.dat'),
    load => 0,
);
$inherited_threshold_model->train_example(
    label     => 'dark',
    features  => [0, 0],
    threshold => 128,
);
$inherited_threshold_model->train_example(
    label    => 'bright',
    features => [255, 255],
);
is(
    $inherited_threshold_model->classifier_stats()->{threshold},
    128,
    'an omitted threshold inherits the existing classifier threshold',
);
is(
    $inherited_threshold_model->classifier_stats()->{total_examples},
    2,
    'training with an inherited threshold adds the example',
);

my $statistics_path = File::Spec->catfile(
    $temporary_directory,
    'statistics.dat',
);
my $statistics_model = TinyLLM->new(path => $statistics_path, load => 0);
$statistics_model->train('red blue');
$statistics_model->train('red green');
$statistics_model->train_example(label => 'cold', features => [0, 0]);
$statistics_model->train_example(label => 'hot', features => [1, 1]);

my $model_stats = $statistics_model->stats();
is_deeply(
    [sort keys %{$model_stats}],
    [qw(
        bigram_count
        classifier
        knowledge_sources
        max_model_bytes
        memory_count
        path
        serialized_bytes
        total_tokens
        version
        vocabulary_size
    )],
    'model stats expose the documented top-level fields only',
);
ok(!exists($model_stats->{algorithm}), 'model stats have no top-level algorithm');
is($model_stats->{version}, $TinyLLM::VERSION, 'model stats report the version');
is($model_stats->{path}, $statistics_path, 'model stats report the save path');
is($model_stats->{total_tokens}, 8, 'model stats report all trained text tokens');
is(
    $model_stats->{vocabulary_size},
    3,
    'vocabulary size excludes the BOS and EOS markers',
);
is(
    $model_stats->{bigram_count},
    5,
    'bigram count measures unique transitions rather than observations',
);
cmp_ok(
    $model_stats->{serialized_bytes},
    '>',
    0,
    'model stats measure the serialized snapshot before it is saved',
);
is_deeply(
    $model_stats->{classifier},
    {
        algorithm             => 'bernoulli_naive_bayes',
        examples_by_label     => { cold => 1, hot => 1 },
        feature_count         => 2,
        label_count           => 2,
        stored_feature_counts => 4,
        threshold             => 0.5,
        total_examples        => 2,
    },
    'model stats contain an independent classifier summary',
);

my $serialized_bytes_without_cache = $model_stats->{serialized_bytes};
$statistics_model->predict(features => [1, 1]);
ok(
    exists($statistics_model->{_classifier_cache}),
    'the regression setup populated the derived classifier cache',
);
is(
    $statistics_model->stats()->{serialized_bytes},
    $serialized_bytes_without_cache,
    'serialized byte measurement excludes the derived classifier cache',
);
$statistics_model->save();
is(
    -s $statistics_path,
    $statistics_model->stats()->{serialized_bytes},
    'reported serialized bytes equal the file written by save',
);
my $saved_statistics = retrieve($statistics_path);
ok(
    !exists($saved_statistics->{_classifier_cache}),
    'save excludes the derived classifier cache from the model file',
);

my $mutable_stats = $statistics_model->stats();
$mutable_stats->{path} = 'somewhere-else.dat';
$mutable_stats->{total_tokens} = 999;
$mutable_stats->{classifier}{threshold} = 999;
$mutable_stats->{classifier}{examples_by_label}{cold} = 999;
my $unchanged_stats = $statistics_model->stats();
is($unchanged_stats->{path}, $statistics_path, 'changing stats cannot redirect saves');
is($unchanged_stats->{total_tokens}, 8, 'changing stats cannot alter token counts');
is(
    $unchanged_stats->{classifier}{threshold},
    0.5,
    'changing nested stats cannot alter classifier preprocessing',
);
is(
    $unchanged_stats->{classifier}{examples_by_label}{cold},
    1,
    'changing nested stats cannot alter classifier counts',
);

my $text_only_stats = TinyLLM->new(
    path => File::Spec->catfile($temporary_directory, 'text-only-stats.dat'),
    load => 0,
)->stats();
ok(!defined($text_only_stats->{classifier}), 'stats use undef without a classifier');

my $unique_save_path = File::Spec->catfile(
    $temporary_directory,
    'unique-save.dat',
);
my $old_predictable_temporary_path = "$unique_save_path.tmp.$$";
write_text($old_predictable_temporary_path, "keep this sentinel\n");
my $unique_save_model = TinyLLM->new(path => $unique_save_path, load => 0);
$unique_save_model->train('unique temporary file');
$unique_save_model->save();
ok(
    -f $old_predictable_temporary_path,
    'save does not consume a predictable process-id temporary path',
);
if (-f $old_predictable_temporary_path) {
    is(
        read_text($old_predictable_temporary_path),
        "keep this sentinel\n",
        'save leaves a colliding predictable temporary file untouched',
    );
} else {
    fail('predictable temporary-file sentinel remains readable');
}

my $failed_save_parent = File::Spec->catdir(
    $temporary_directory,
    'failed-save-parent',
);
mkdir $failed_save_parent or die "Could not create $failed_save_parent: $!";
my $directory_as_model_path = File::Spec->catdir(
    $failed_save_parent,
    'model.dat',
);
mkdir $directory_as_model_path
    or die "Could not create $directory_as_model_path: $!";
my @entries_before_failed_save = directory_entries($failed_save_parent);
my $failed_save_model = TinyLLM->new(
    path => $directory_as_model_path,
    load => 0,
);
$failed_save_model->train('this save must fail');
$error = '';
eval { $failed_save_model->save(); 1 } or $error = $@;
like($error, qr/(?:fail|cannot|directory)/i, 'a model cannot replace a directory');
is_deeply(
    [directory_entries($failed_save_parent)],
    \@entries_before_failed_save,
    'a failed save cleans up its temporary file',
);

my $reply_model = TinyLLM->new(
    path => File::Spec->catfile($temporary_directory, 'reply-validation.dat'),
    load => 0,
);
$reply_model->train('winner') for 1 .. 10;
$reply_model->train('other');
is(
    $reply_model->reply(prompt => '', max_tokens => 0),
    '',
    'reply accepts zero as a token limit',
);
for my $invalid_max_tokens (-1, 1.5, 'many', 'NaN', 'Inf') {
    $error = '';
    eval {
        $reply_model->reply(
            prompt     => '',
            max_tokens => $invalid_max_tokens,
        );
        1;
    } or $error = $@;
    like(
        $error,
        qr/max_tokens.*nonnegative integer/i,
        "reply rejects invalid max_tokens '$invalid_max_tokens'",
    );
}
for my $invalid_temperature ('cold', 'NaN', 'Inf', '-Inf') {
    $error = '';
    eval {
        $reply_model->reply(
            prompt      => '',
            max_tokens  => 1,
            temperature => $invalid_temperature,
        );
        1;
    } or $error = $@;
    like(
        $error,
        qr/temperature.*finite number/i,
        "reply rejects invalid temperature '$invalid_temperature'",
    );
}
is(
    $reply_model->reply(
        prompt      => '',
        max_tokens  => 1,
        temperature => 1e-300,
    ),
    'winner',
    'tiny positive temperatures sample stably in log space',
);
$error = '';
eval {
    $reply_model->reply(
        prompt      => '',
        max_tokens  => 1,
        temperature => 1e308,
    );
    1;
} or $error = $@;
is($error, '', 'a very large finite temperature remains valid');

srand 12_345;
my $unit_temperature_reply = $reply_model->reply(
    prompt      => '',
    max_tokens  => 4,
    temperature => 1,
);
srand 12_345;
is(
    $reply_model->reply(
        prompt      => '',
        max_tokens  => 4,
        temperature => 0,
    ),
    $unit_temperature_reply,
    'zero temperature keeps the historical unit-temperature fallback',
);
srand 12_345;
is(
    $reply_model->reply(
        prompt      => '',
        max_tokens  => 4,
        temperature => -2,
    ),
    $unit_temperature_reply,
    'negative temperature keeps the historical unit-temperature fallback',
);

my $corrupt_path = File::Spec->catfile($temporary_directory, 'corrupt.dat');
open my $corrupt_file, '>', $corrupt_path
    or die "Could not write corrupt test model: $!";
print {$corrupt_file} "not a Storable model\n";
close $corrupt_file;
$error = '';
eval { TinyLLM->new(path => $corrupt_path); 1 } or $error = $@;
like($error, qr/Failed to load model/, 'an unreadable existing model fails loudly');

my $invalid_schema_path = File::Spec->catfile(
    $temporary_directory,
    'invalid-schema.dat',
);
nstore(
    {
        unigrams     => {},
        bigrams      => { hello => [] },
        total_tokens => 0,
    },
    $invalid_schema_path,
);
$error = '';
eval { TinyLLM->new(path => $invalid_schema_path); 1 } or $error = $@;
like($error, qr/invalid bigram row/, 'invalid model contents fail during load');

my $legacy_path = File::Spec->catfile($temporary_directory, 'legacy.dat');
nstore(
    {
        unigrams => { '<BOS>' => 1, hello => 1, '<EOS>' => 1 },
        bigrams  => {
            '<BOS>' => { hello => 1 },
            hello   => { '<EOS>' => 1 },
        },
    },
    $legacy_path,
);
my $legacy_disk_bytes = -s $legacy_path;
my $legacy_model = TinyLLM->new(path => $legacy_path);
ok($legacy_model, 'a permissive v0.1 plain-hash model still loads');
is(
    $legacy_model->stats()->{total_tokens},
    3,
    'legacy migration reconstructs total tokens from unigram counts',
);
isnt(
    $legacy_model->stats()->{serialized_bytes},
    $legacy_disk_bytes,
    'legacy stats measure the migrated snapshot rather than the old file',
);
$legacy_model->save();
is(
    $legacy_model->stats()->{serialized_bytes},
    -s $legacy_path,
    'legacy stats match disk size after saving the migrated model',
);

my $tie_model = TinyLLM->new(
    path => File::Spec->catfile($temporary_directory, 'ties.dat'),
    load => 0,
);
for my $label ('2', '10', '11a') {
    $tie_model->train_example(label => $label, features => [1]);
}
is(
    $tie_model->predict(features => [1])->{label},
    '10',
    'equal classifier scores use a deterministic lexical label tie-break',
);

done_testing();

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
    close $file or die "Could not close $path: $!";
    return $content;
}

sub directory_entries {
    my ($path) = @_;
    opendir my $directory, $path or die "Could not read $path: $!";
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir $directory;
    closedir $directory or die "Could not close $path: $!";
    return @entries;
}
