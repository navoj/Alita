use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Storable qw(dclone nstore);
use lib "$FindBin::RealBin/../lib";
use TinyLLM;

my $directory = tempdir(CLEANUP => 1);
my $path = File::Spec->catfile($directory, 'bounded.dat');
my $model = TinyLLM->new(path => $path, load => 0, max_model_bytes => 2048);
is($model->stats->{max_model_bytes}, 2048, 'a lower model budget is supported');
is(TinyLLM->new(load => 0)->stats->{max_model_bytes}, 4_000_000_000,
    'the default budget is exactly 4 GB in decimal bytes');
for my $invalid (0, -1, 2.5, 'many', 'Inf', 'NaN', 4_000_000_001, []) {
    like(exception(sub { TinyLLM->new(load => 0, max_model_bytes => $invalid) }),
        qr/max_model_bytes.*integer.*4 GB/, 'invalid or above-ceiling budget is rejected');
}
like(exception(sub { TinyLLM->new(load => 0, max_model_bytes => 1) }),
    qr/size limit exceeded/, 'even an empty model must fit its configured budget');

my $digest = 'a' x 64;
$model->learn(
    texts => ['Alita remembers a useful answer.'],
    memories => [
        { kind => 'teaching', prompt => 'Who are you?', text => 'I am Alita.' },
        { kind => 'file', source => 'notes.txt', digest => $digest, text => 'A lunar fact.' },
        { kind => 'file', source => 'notes.txt', digest => $digest, text => 'Another lunar fact.' },
    ],
);
is($model->stats->{memory_count}, 3, 'memory records are counted');
is($model->stats->{knowledge_sources}, 1, 'source count measures distinct paths, not chunks');
my $copies = $model->memories;
$copies->[0]{text} = 'not the original';
push @{$copies}, { kind => 'conversation', text => 'extra' };
is($model->memories->[0]{text}, 'I am Alita.', 'memory inspection cannot mutate stored knowledge');
is($model->stats->{memory_count}, 3, 'returned memory array is independent');

my $incoming = { kind => 'conversation', prompt => 'hello', text => 'hello' };
$model->learn(memories => [$incoming]);
$incoming->{text} = 'changed outside the model';
is($model->memories->[-1]{text}, 'hello', 'incoming memory hashes are copied');
$model->save;
my $before = dclone($model->_snapshot);
my $disk_before = read_bytes($path);
like(exception(sub {
    $model->learn(
        texts => ['new words must all roll back'],
        memories => [{ kind => 'conversation', text => 'x' x 5000 }],
    );
}), qr/size limit exceeded/, 'oversized combined text and memory learning is rejected');
is_deeply($model->_snapshot, $before, 'failed learning rolls back every token and memory change');
is(read_bytes($path), $disk_before, 'rejected learning does not change the saved model');
like(exception(sub { $model->train('z' x 5000) }), qr/size limit exceeded/,
    'plain text training also obeys the model budget');
is_deeply($model->_snapshot, $before, 'rejected plain training restores all counts');

like(exception(sub {
    $model->learn(texts => ['must not learn this'], memories => [{ kind => 'unknown', text => 'bad' }]);
}), qr/memory kind/, 'malformed memories are validated before learning');
is_deeply($model->_snapshot, $before, 'invalid memory input cannot partially train text');
like(exception(sub { $model->learn(memories => [{kind => 'teaching', text => 'answer'}]) }),
    qr/requires.*prompt/, 'teaching requires a question');
like(exception(sub { $model->learn(memories => [{kind => 'file', text => 'fact', source => 'file'}]) }),
    qr/SHA-256 digest/, 'file memory requires provenance and a digest');
like(exception(sub { $model->learn(texts => ['valid', []]) }), qr/array of strings/,
    'invalid text lists are rejected');

my $reloaded = TinyLLM->new(path => $path);
is($reloaded->stats->{max_model_bytes}, 2048, 'a saved lower budget survives reload');
is_deeply($reloaded->memories, $model->memories, 'memories survive save and reload');
is(-s $path, $model->stats->{serialized_bytes}, 'size report equals actual saved bytes');
is(TinyLLM->new(path => $path, max_model_bytes => 4096)->stats->{max_model_bytes}, 4096,
    'an explicit within-ceiling override can raise a saved lower budget');
like(exception(sub { TinyLLM->new(path => $path, max_model_bytes => 100) }),
    qr/size limit exceeded before load/, 'file size is checked before deserializing');

my $oversized_path = File::Spec->catfile($directory, 'not-storable.dat');
open my $oversized, '>:raw', $oversized_path or die $!;
print {$oversized} 'not a model' x 1000;
close $oversized or die $!;
like(exception(sub { TinyLLM->new(path => $oversized_path, max_model_bytes => 2048) }),
    qr/size limit exceeded before load/, 'oversized invalid files never reach deserialization');

# The save guard also protects against unsupported direct hash modifications.
$model->{memories}[0]{text} = 'y' x 5000;
like(exception(sub { $model->save }), qr/size limit exceeded/, 'save refuses an oversized snapshot');
is(read_bytes($path), $disk_before, 'an oversized save preserves the existing good file');
opendir my $listing, $directory or die $!;
my @leftovers = grep { /^tinyllm-model-/ } readdir $listing;
closedir $listing;
is_deeply(\@leftovers, [], 'failed saves do not leave temporary model files');

my $class_model = TinyLLM->new(path => File::Spec->catfile($directory, 'class.dat'),
    load => 0, max_model_bytes => 2048);
my $empty_class = dclone($class_model->_snapshot);
like(exception(sub { $class_model->train_example(label => 'large', features => [(1) x 2000]) }),
    qr/size limit exceeded/, 'classifier training shares the same size ceiling');
is_deeply($class_model->_snapshot, $empty_class, 'a rejected first classifier example is fully rolled back');
$class_model->train_example(label => 'one', features => [1, 0]);
$class_model->predict(features => [1, 0]);
my $before_class = dclone($class_model->_snapshot);
my $prediction = $class_model->predict(features => [1, 0]);
like(exception(sub { $class_model->train_example(label => 'q' x 5000, features => [0, 1]) }),
    qr/size limit exceeded/, 'a new oversized classifier label is rejected');
is_deeply($class_model->_snapshot, $before_class, 'existing classifier counts survive budget rejection');
is_deeply($class_model->predict(features => [1, 0]), $prediction,
    'cached classifier predictions remain consistent after rollback');

# Storable count cells grow when 127 becomes 128. This exercises rollback of
# an existing label, not just rejection of a newly allocated label.
my $count_boundary = TinyLLM->new(path => File::Spec->catfile($directory, 'count-boundary.dat'),
    load => 0, max_model_bytes => 1100);
$count_boundary->train_example(label => 'one', features => [(1) x 200]) for 1 .. 127;
my $boundary_prediction = $count_boundary->predict(features => [(1) x 200]);
my $boundary_before = dclone($count_boundary->_snapshot);
like(exception(sub { $count_boundary->train_example(label => 'one', features => [(1) x 200]) }),
    qr/size limit exceeded/, 'existing classifier counts cannot grow beyond the cap');
is_deeply($count_boundary->_snapshot, $boundary_before,
    'existing-label count overflow rolls back feature and total counts');
is_deeply($count_boundary->predict(features => [(1) x 200]), $boundary_prediction,
    'an existing-label rollback restores its prediction cache');

my $history_model = TinyLLM->new(path => File::Spec->catfile($directory, 'history.dat'), load => 0);
$history_model->learn(memories => [
    { kind => 'teaching', prompt => 'keep teaching', text => 'keep this answer' },
    { kind => 'file', source => 'keep.txt', digest => $digest, text => 'keep this file' },
    map { { kind => 'conversation', prompt => "turn $_", text => "turn $_" } } 1 .. 210,
]);
my $history = $history_model->memories;
is(scalar @{$history}, 202, 'conversation history is bounded separately from teaching and files');
is($history->[0]{kind}, 'teaching', 'history pruning keeps teaching records');
is($history->[1]{kind}, 'file', 'history pruning keeps file records');
is($history->[2]{text}, 'turn 11', 'oldest conversation memories are pruned');
is($history->[-1]{text}, 'turn 210', 'newest conversation memory is retained');

my $unbounded_history_path = File::Spec->catfile($directory, 'old-history.dat');
my $unbounded_history = dclone($history_model->_snapshot);
$unbounded_history->{memories} = [
    { kind => 'teaching', prompt => 'keep teaching', text => 'keep this answer' },
    map { { kind => 'conversation', text => "loaded turn $_" } } 1 .. 205,
];
nstore($unbounded_history, $unbounded_history_path);
my $bounded_reload = TinyLLM->new(path => $unbounded_history_path);
is($bounded_reload->stats->{memory_count}, 201, 'loading also enforces the conversation-history bound');
is($bounded_reload->memories->[1]{text}, 'loaded turn 6', 'load keeps the latest 200 conversation turns');
is($bounded_reload->memories->[0]{kind}, 'teaching', 'load-time pruning preserves teachings');

my $invalid_metadata_path = File::Spec->catfile($directory, 'invalid-metadata.dat');
nstore({ unigrams => {}, bigrams => {}, total_tokens => 0, max_model_bytes => 4_000_000_001,
    memories => [] }, $invalid_metadata_path);
like(exception(sub { TinyLLM->new(path => $invalid_metadata_path) }),
    qr/Invalid TinyLLM model.*max_model_bytes/s, 'invalid persisted limits are rejected');
nstore({ unigrams => {}, bigrams => {}, total_tokens => 0, memories => 'bad' }, $invalid_metadata_path);
like(exception(sub { TinyLLM->new(path => $invalid_metadata_path) }),
    qr/Invalid TinyLLM model.*memories/s, 'invalid memory schemas fail during loading');

done_testing;

sub exception {
    my ($action) = @_;
    return eval { $action->(); 1 } ? '' : $@;
}
sub read_bytes {
    my ($file) = @_;
    open my $input, '<:raw', $file or die $!;
    my $bytes = do { local $/; <$input> };
    close $input or die $!;
    return $bytes;
}
