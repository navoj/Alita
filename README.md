# Alita

Alita is a collection of Perl experiments in conversational learning,
probabilistic text generation, supervised classification, and evolutionary
programming. The actively reusable part of the project is `lib/TinyLLM.pm`.

TinyLLM is intentionally small and educational. It is not a transformer or a
large language model. It supports two independent learning modes in one saved
model:

- a word-bigram generator for short text experiments; and
- a Bernoulli naive Bayes classifier for labeled numeric feature vectors.

The classifier makes the digit-recognition example genuine supervised
classification. Trying to feed 784 pixels through the text `train`/`reply`
methods would not recognize unseen images, because the text model considers
only one previous word.

## Project layout

- `lib/TinyLLM.pm` - reusable text-generation and classification library.
- `alitaLLM.pl` - interactive text trainer and generator backed by TinyLLM.
- `examples/digit_recognizer.pl` - trains, evaluates, and runs a handwritten
  digit classifier.
- `examples/model_info.pl` - inspects a saved TinyLLM model without changing it.
- `digit-recognizer/` - local CSV data used by the example. Large data files
  are ignored by Git.
- `t/` - automated tests.
- `alita.pl`, `archive/`, `form_fitter_v1p0/`, and `unhash_project/` - legacy
  experiments that are separate from the TinyLLM digit pipeline.

## How TinyLLM works

### Text mode

`train($text)` lowercases words, keeps ASCII letters, digits, and apostrophes,
and counts individual words and adjacent word pairs. `reply(...)` starts with
the last word in the prompt and samples one word at a time from the learned
bigram counts. `temperature` controls how random that sampling is.

This is useful for demonstrating tokenization, incremental counts, sampling,
and persistence. It has only one token of context and will not behave like a
modern chat model.

### Classification mode

`train_example(...)` receives a label and a fixed-length numeric vector. Each
feature is converted to active/inactive using a threshold. For every label,
TinyLLM counts how often each feature is active. `predict(...)` applies a
smoothed Bernoulli naive Bayes calculation and returns the most likely label,
its confidence, and the probability assigned to every known label.

That confidence is a probability normalized within the naive Bayes model. It
is not a calibrated estimate of real-world accuracy, because the calculation
assumes the features are conditionally independent.

For the digit example, each input is a flattened 28 x 28 image: 784 grayscale
pixels from 0 through 255. With the example's default `--threshold=128`, pixels
at or above 128 are considered active. The classifier is a compact baseline,
not a convolutional neural network; it is intended to make the training
process easy to inspect.

### Persistence

Both learning modes are saved together with Perl's `Storable` module. By
default, `new(path => ...)` loads an existing model automatically. Training is
additive in memory, and nothing is written until `save()` is called.

If an existing path is not a readable TinyLLM model, loading stops with an
error instead of silently replacing it with a fresh model.

Model files are Perl-specific and should be treated as application data, not
as a portable exchange format. Only load model files you trust.

### What makes a model grow

TinyLLM stores counts, not copies of the training examples. A ten-label digit
model stores one active count for each label/feature combination: 10 x 784 =
7,840 feature counts, plus one example count for each of the 10 labels. Adding
more 784-pixel rows increases those counts but does not add another stored
image. The verified 40,000-row model is therefore only 26,262 bytes (25.65 KiB)
on disk, although Perl's in-memory arrays and hashes use more memory.

Text-model size grows mainly when training introduces new words or new unique
word-to-word transitions. Repeating known text changes the stored counts but
does not create another vocabulary or transition entry. Use `stats()` or
`examples/model_info.pl` to inspect these quantities and the serialized size.

## Requirements

TinyLLM and the examples require Perl and modules included with the standard
Perl distribution (`File::Basename`, `File::Path`, `File::Spec`, `File::Temp`,
`FindBin`, `Getopt::Long`, `JSON::PP`, `POSIX`, `Scalar::Util`, and `Storable`).
No machine-learning framework is required.

The legacy `alita.pl` experiment has separate requirements: a threaded Perl
build and the CPAN modules `IO::Scalar` and `Term::ReadKey`.

Run commands below from the project root.

## Library endpoints

TinyLLM is a Perl library; it does not expose HTTP or REST endpoints. Its public
methods are:

| Method | Purpose |
| --- | --- |
| `TinyLLM->new(path => $file)` | Create a model and load `$file` when it exists. The default path is `myBrainLLM.dat`. |
| `TinyLLM->new(path => $file, load => 0)` | Create a fresh model without loading an existing file at that path. A later `save()` replaces the path. |
| `$model->train($text)` | Add one text sample to the unigram and bigram counts. |
| `$model->reply(prompt => $text, max_tokens => 50, temperature => 0.9)` | Generate text from the learned bigrams and return a string. `max_tokens` must be a nonnegative integer and temperature must be finite; a nonpositive temperature falls back to `1.0`. |
| `$model->train_example(label => $label, features => \@values, threshold => $number)` | Add one labeled numeric vector. When omitted, `threshold` inherits an existing classifier's threshold or defaults to `0.5` for a fresh classifier. An explicit mismatch is rejected. |
| `$model->predict(features => \@values, alpha => 1)` | Return `{ label, confidence, probabilities }`. `alpha` is the positive smoothing value; confidence is normalized within the model, not calibrated accuracy. |
| `$model->classifier_stats()` | Return `{ algorithm, feature_count, label_count, stored_feature_counts, threshold, total_examples, examples_by_label }`, or `undef` before classifier training. |
| `$model->stats()` | Return `{ version, path, total_tokens, vocabulary_size, bigram_count, serialized_bytes, classifier }`. Tokens include sentence boundaries; vocabulary excludes `<BOS>` and `<EOS>`; bigrams count unique transitions; serialized bytes describe the current cache-free state if saved. |
| `$model->save()` | Save text and classifier state to the model's path. Parent directories are created when needed. |

Methods beginning with an underscore are implementation details and are not
public endpoints.

## Use the text model

Start the interactive command-line program:

```powershell
perl alitaLLM.pl
```

Each input line is learned immediately, then used as the prompt for a reply.
Press Ctrl+Z followed by Enter on Windows, or Ctrl+D on Unix-like systems, to
send end-of-file and save. Ctrl+C also saves before exiting.

Choose another model path with an argument or environment variable:

```powershell
perl alitaLLM.pl --model=my-text-model.dat
$env:ALITA_LLM_PATH = 'my-text-model.dat'
perl alitaLLM.pl
```

A minimal library example looks like this:

```perl
use lib 'lib';
use TinyLLM;

my $model = TinyLLM->new(path => 'my-text-model.dat');
$model->train('the red bird sings');
$model->train('the blue bird flies');
$model->save();

my $reply = $model->reply(
    prompt      => 'the',
    max_tokens  => 20,
    temperature => 0.8,
);
print "$reply\n";
```

## Train the digit-recognition example

The example expects these local files:

- `digit-recognizer/train.csv` - 42,000 labeled rows with columns
  `label,pixel0,...,pixel783`.
- `digit-recognizer/test.csv` - 28,000 unlabeled rows with columns
  `pixel0,...,pixel783`.
- `digit-recognizer/sample_submission.csv` - an illustration of the expected
  `ImageId,Label` output shape; the script does not need to read it.

The CSV parser deliberately accepts only this simple numeric format. It checks
the headers, row width, labels, and pixel range so malformed training data does
not silently change the model.

For a quick end-to-end run, consider 5,000 rows, reserve the first 1,000 for
validation, and train on the remaining 4,000:

```powershell
perl examples/digit_recognizer.pl train --limit=5000 --validation=1000 --overwrite
```

To use the entire file while retaining 2,000 held-out validation images:

```powershell
perl examples/digit_recognizer.pl train --validation=2000 --overwrite
```

Training reports the saved model's byte and KiB size after validation succeeds.

With the supplied CSV, this 40,000-training/2,000-validation split scored
1,670 out of 2,000 (83.50%) during project verification. Treat that as an
educational baseline rather than competitive image-recognition performance.

The holdout is the first 2,000 rows; it is not randomized or stratified. For a
more rigorous assessment, prepare a representative holdout that is never used
for training.

For a final model trained on every labeled row, do not reserve a validation
set:

```powershell
perl examples/digit_recognizer.pl train --validation=0 --overwrite
```

The default model is `examples/tinyllm-digits.dat`. Generate predictions for
`test.csv` in the same row order:

```powershell
perl examples/digit_recognizer.pl predict --overwrite
```

This writes `examples/digit-submission.csv` with `ImageId,Label` columns and
one-based image IDs. Use `--data`, `--model`, and `--output` to choose other
paths. Use `--limit=N` for a smaller smoke test. All options are listed by:

```powershell
perl examples/digit_recognizer.pl help
```

### Evaluate a saved digit model

`evaluate` reports overall accuracy and accuracy for each digit without
training or saving the model. If the model was trained with the default first
2,000 rows held out, evaluate that same holdout with:

```powershell
perl examples/digit_recognizer.pl evaluate --data="digit-recognizer\train.csv" --model="examples\tinyllm-digits.dat" --limit=2000
```

Evaluating rows that the model was trained on measures in-sample fit and will
usually overestimate performance on new images. In particular, evaluating all
of `train.csv` against the 40,000-row model mixes 40,000 training rows into the
2,000-row holdout result.

### Inspect a saved model

The inspection example requires an existing model and never writes to it. With
no option, it reads the text model `myBrainLLM.dat`:

```powershell
perl examples/model_info.pl
perl examples/model_info.pl --model="examples\tinyllm-digits.dat"
perl examples/model_info.pl --model="C:\path with spaces\tinyllm.dat" --json
```

The report includes the file's actual disk size and the fields returned by
`stats()`. `serialized_bytes` is the current loaded state if saved, so it can
differ from the existing file after loading an older model or a copy stored at
a new path. The checked-in `myBrainLLM.dat` is currently 446 bytes; the trained
digit model is 26,262 bytes (25.65 KiB) because it stores aggregate counts
rather than the source images.

Generated models and prediction CSVs in `examples/` are ignored by Git.

## Train TinyLLM with new data

### Add new text

Open the same model path, call `train` once for each new text sample, and save:

```perl
my $model = TinyLLM->new(path => 'my-text-model.dat'); # loads existing data
for my $sentence (@new_sentences) {
    $model->train($sentence);
}
$model->save();
```

TinyLLM updates counts; it does not run epochs or backpropagation. Training the
same sentence again gives its word transitions more weight.

### Add new labeled vectors or digit images

Use exactly the same feature order, feature count, and threshold as the
existing classifier:

```perl
my $model = TinyLLM->new(path => 'examples/tinyllm-digits.dat');
$model->train_example(
    label     => 7,
    features  => \@pixels, # 784 values in pixel0 ... pixel783 order
    threshold => 128,
);
$model->save();
```

For a CSV containing genuinely new labeled digit rows, continue the saved
model from the command line:

```powershell
perl examples/digit_recognizer.pl train --data="C:\path with spaces\new-digits.csv" --model="examples\tinyllm-digits.dat" --validation=0 --resume
```

`--resume` is additive. Do not replay the original CSV unless you intentionally
want to count every original row again. To retrain from scratch instead, use a
new `--model` path or explicitly pass `--overwrite`.

When resuming, omit `--threshold` to inherit the value stored in the model. You
may pass it explicitly as a consistency check; a mismatch is rejected. Always
pass the same custom `--model` path if the model is not at the default path.

If preprocessing changes (for example, a different pixel threshold or feature
order), start a fresh model. TinyLLM rejects feature-count and threshold
mismatches, but it cannot detect reordered features that still have the same
length.

## Tests

Run the complete test suite:

```powershell
prove -lvr t
```

Run only the TinyLLM unit tests:

```powershell
prove -lv t/tinyllm.t
```

See `TESTING.md` for additional commands and the digit-example smoke test.

## License

Alita is licensed under the GNU General Public License v3.0. See `LICENSE`.
