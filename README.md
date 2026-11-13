# Alita

Alita is a collection of Perl experiments in conversational learning,
probabilistic text generation, supervised classification, and evolutionary
programming. The actively reusable part of the project is `lib/TinyLLM.pm`.

TinyLLM is intentionally small and educational. It is not a transformer or a
large language model. One saved model can contain:

- a word-bigram generator for short text experiments;
- a Bernoulli naive Bayes classifier for labeled numeric feature vectors; and
- bounded conversation, teaching, and explicitly ingested file memories.

The classifier makes the digit-recognition example genuine supervised
classification. Trying to feed 784 pixels through the text `train`/`reply`
methods would not recognize unseen images, because the text model considers
only one previous word.

## Project layout

- `lib/TinyLLM.pm` - reusable text, classification, memory, and persistence library.
- `lib/Alita/Agent.pm` - local recall and explicit-file knowledge layer.
- `alitaLLM.pl` - interactive local recall, teaching, and file-knowledge CLI.
- `examples/conversation.pl` - self-contained teaching, recall, and explicit-file
  demonstration.
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

### Local recall and explicit knowledge

`Alita::Agent` adds bounded local memory on top of TinyLLM. It can recall
recent conversation entries, exact question/answer teachings, and excerpts
from text files that the user explicitly asks it to read. Taught answers and
file excerpts are retrieved before the current question is added to the
model's text counts.

The agent's replies are deterministic retrieval results or readable canned
guidance when nothing matches; it does not call the stochastic bigram
generator. Chat, teaching, and file text still train TinyLLM's separate
low-level `reply()` model. Together these provide memory plus a small bigram
experiment, not a transformer or general free-form document reasoning. The
agent does not browse or run commands, and file contents are treated only as
data, never as instructions for the program to execute.

Retrieval checks an exact taught prompt first. A non-exact teaching is matched
against its prompt, not its answer, and requires at least 75% keyword coverage
in both directions. For any multi-keyword query, a teaching or file chunk must
share at least two meaningful keywords; a one-keyword query must share that
one. Teaching wins a score tie with a file chunk, and the newest entry wins
remaining ties. Recent-conversation recall also requires at least 75% coverage
of the query keywords. Clear personal statements such as “My favorite
constellation is Orion” receive an acknowledgement and can be recalled later;
declarative memories take priority over repeated earlier questions. Follow-up
phrases such as “tell me more” reuse the previous user turn to search teachings
and file chunks rather than conversation history.

TinyLLM keeps at most the latest 200 conversation-memory entries. Dropping an
older recall entry does not subtract its cumulative text counts. Teaching and
file memories remain until the configured model-size cap prevents another
atomic learning operation. Memory entries use these fields:

```perl
{
    kind   => $kind,  # 'conversation', 'teaching', or 'file'
    text   => $text,
    prompt => $optional_prompt,
    source => $optional_file_path,
    digest => $optional_content_digest,
}
```

Every entry requires `kind` and string `text`. A teaching also requires a
nonempty `prompt`; a file entry requires `source` and a 64-character SHA-256
`digest`. The agent stores a user utterance as both conversation `prompt` and
`text`, a taught answer as teaching `text`, and each source chunk as file
`text`. The remaining fields are optional for the other kinds.

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

Text counts, classifier state, and local memories are saved together with
Perl's `Storable` module. By default, `new(path => ...)` loads an existing model
automatically. Low-level library changes remain in memory until `save()` is
called; the interactive agent autosaves learned operations.

If an existing path is not a readable TinyLLM model, loading stops with an
error instead of silently replacing it with a fresh model.

Model files are Perl-specific and should be treated as application data, not
as a portable exchange format. Only load model files you trust.

Conversation text, taught answers, imported file excerpts, and source paths
are stored as recoverable text inside the Storable file; they are not
encrypted. The default `myBrainLLM.dat` is tracked by Git in this repository.
For personal or sensitive knowledge, use an ignored path such as
`--model=examples/alita-chat.dat`, and do not commit or share the resulting
model file.

### Saved-model size limit

Every model has a default cap and hard ceiling of 4,000,000,000 serialized
bytes: decimal 4 GB, approximately 3.73 GiB. `max_model_bytes` may set any
positive limit up to that ceiling. A loaded model retains its saved smaller
limit unless the caller explicitly overrides it. The cap covers the complete
saved model, including text counts, classifier counts, conversations,
teachings, and ingested file memories.

An existing file larger than the configured cap is rejected before Storable
deserialization. `train()`, `learn()`, and `train_example()` check the
prospective serialized model and reject an over-cap update without retaining a
partial change. Saving writes and checks a unique temporary file before
replacing the destination, so a failed size check does not overwrite the prior
model.

This is a serialized-storage limit, not a Perl RAM limit or a limit on total
temporary, backup, or filesystem space. Size checks can themselves allocate
serialization buffers, and each checked mutation serializes the complete
prospective snapshot, so update cost grows with the model. Perl's live hashes
and arrays can occupy much more than the saved file; a process may run out of
memory before approaching the 4 GB storage ceiling. The ceiling is not a
claim that TinyLLM is a 4 GB neural language model.

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
Conversation, teaching, and file memories retain their text and therefore also
contribute directly to the saved-model cap.

## Requirements

TinyLLM and the examples require Perl and modules included with the standard
Perl distribution (`Cwd`, `Digest::SHA`, `Encode`, `Errno`, `File::Basename`,
`File::Path`, `File::Spec`, `File::Temp`, `FindBin`, `Getopt::Long`, `JSON::PP`,
`POSIX`, `Scalar::Util`, `Storable`, and `Time::HiRes`). No machine-learning
framework is required.

The legacy `alita.pl` experiment has separate requirements: a threaded Perl
build and the CPAN modules `IO::Scalar` and `Term::ReadKey`.

Run commands below from the project root.

## Library endpoints

TinyLLM is a Perl library; it does not expose HTTP or REST endpoints. Its public
methods are:

| Method | Purpose |
| --- | --- |
| `TinyLLM->new(path => $file, max_model_bytes => $bytes)` | Create a model and load `$file` when it exists. Defaults are `myBrainLLM.dat` and 4,000,000,000 bytes. A loaded saved limit is retained unless explicitly overridden; the hard ceiling cannot be exceeded. Oversized files are rejected before deserialization. |
| `TinyLLM->new(path => $file, load => 0)` | Create a fresh model without loading an existing file at that path. A later `save()` replaces the path. |
| `$model->train($text)` | Add one text sample to the unigram and bigram counts. |
| `$model->learn(texts => \@strings, memories => \@entries)` | Atomically add text samples and validated memory entries. If the complete update exceeds the model cap, none of it is retained. |
| `$model->memories()` | Return a deep copy of the stored conversation, teaching, and file-memory entries. |
| `$model->reply(prompt => $text, max_tokens => 50, temperature => 0.9)` | Generate text from the learned bigrams and return a string. `max_tokens` must be a nonnegative integer and temperature must be finite; a nonpositive temperature falls back to `1.0`. |
| `$model->train_example(label => $label, features => \@values, threshold => $number)` | Add one labeled numeric vector. When omitted, `threshold` inherits an existing classifier's threshold or defaults to `0.5` for a fresh classifier. An explicit mismatch is rejected. |
| `$model->predict(features => \@values, alpha => 1)` | Return `{ label, confidence, probabilities }`. `alpha` is the positive smoothing value; confidence is normalized within the model, not calibrated accuracy. |
| `$model->classifier_stats()` | Return `{ algorithm, feature_count, label_count, stored_feature_counts, threshold, total_examples, examples_by_label }`, or `undef` before classifier training. |
| `$model->stats()` | Return `{ version, path, max_model_bytes, serialized_bytes, total_tokens, vocabulary_size, bigram_count, memory_count, knowledge_sources, classifier }`. Knowledge sources count unique file paths. Tokens include sentence boundaries; vocabulary excludes `<BOS>` and `<EOS>`; bigrams count unique transitions. `serialized_bytes` describes the current cache-free state if saved. |
| `$model->save()` | Size-check and save all model state through a unique temporary file, then replace the model path. Parent directories are created when needed. |

Methods beginning with an underscore are implementation details and are not
public endpoints.

`Alita::Agent` provides the higher-level recall interface:

| Method | Purpose |
| --- | --- |
| `Alita::Agent->new(model => $model, max_file_bytes => $bytes)` | Wrap a TinyLLM model and configure the per-file ingestion limit. The default is 10 MiB and the hard maximum is 4,000,000,000 bytes. |
| `$agent->chat($prompt)` | Retrieve a relevant taught answer, source excerpt, or recent conversation when available, then atomically learn the prompt as a conversation entry. The CLI saves it. |
| `$agent->teach(prompt => $question, response => $answer)` | Atomically store an exact question/answer teaching and train both strings. |
| `$agent->ingest_file($path)` | Atomically learn chunks of at most 1,500 characters from one explicitly named regular UTF-8 text file, including files with a UTF-8 BOM. Return `{ source, digest, bytes, chunks, duplicate, changed }`. It does not recurse, browse, or execute anything. |
| `$agent->sources()` | Return a sorted array reference of `{ source, digest, chunks }` records, one per source/digest fingerprint. |

Agent methods update the in-memory TinyLLM but do not call `save()` themselves.
Call `$model->save()` in library code; `alitaLLM.pl` performs the autosaves
described below.

## Run the bundled conversation example

The self-contained example teaches Alita its identity, remembers that the
user's favorite constellation is Orion, imports the bundled fictional Lantern
workshop notes, asks which city hosts the workshop, and saves the result:

```powershell
perl examples/conversation.pl
```

Its default model is `examples/alita-chat-demo.dat`, which is ignored by Git.
Use `--model=PATH`, `--knowledge=PATH`, or `--max-model-bytes=N` to change the
inputs. Repeated runs add conversation and teaching counts; importing the same
source content again is a no-op. Run `perl examples/conversation.pl --help` for
all options.

## Use the conversation and knowledge agent

Start the interactive command-line program:

```powershell
perl alitaLLM.pl --model=examples/alita-chat.dat
```

An ordinary input line asks a question. The agent first searches locally stored
teachings, file excerpts, and recent conversation. When nothing matches, it
gives readable guidance about `/teach` and `/read`, rather than emitting a
random bigram reply. It records the turn only after retrieval, so the current
question cannot match itself. Learned turns, teachings, and successful file
reads are saved automatically. Input and output streams use UTF-8;
whitespace-only lines are skipped.

For example, teach a fact, ask the same question, import this README, and ask
a question containing words from the imported text:

```text
/teach What color is the lab door? => The lab door is blue.
What color is the lab door?
/read "README.md"
What is the default model cap?
Tell me more.
/sources
/stats
/quit
```

The exact taught question returns its saved answer. File recall uses keyword
overlap, so wording a question with terms that occur in the source generally
works better than an unrelated or highly abstract question. “Tell me more”
reuses the preceding user question as retrieval context.

Interactive commands are:

| Command | Effect |
| --- | --- |
| `/teach question => answer` | Store an explicit question/answer teaching. |
| `/read "C:\path with spaces\notes.txt"` | Read one explicitly named local text file. |
| `/sources` | List imported source paths, digests, and chunk counts. |
| `/stats` | Show model counts, serialized size, and configured limits. |
| `/save` | Save immediately. |
| `/help` | Show commands and options. |
| `/quit` or `/exit` | Save and exit. |

Press Ctrl+Z followed by Enter on Windows, or Ctrl+D on Unix-like systems, to
send end-of-file and save. Ctrl+C also saves before exiting.

Choose another model path with an argument or environment variable, or
configure the model and per-file limits:

```powershell
perl alitaLLM.pl --model=my-text-model.dat
$env:ALITA_LLM_PATH = 'my-text-model.dat'
perl alitaLLM.pl
perl alitaLLM.pl --model="C:\path with spaces\brain.dat" --max-model-bytes=50000000 --max-file-bytes=1048576
```

Run `perl alitaLLM.pl --help` for the complete command-line help. On a fresh
model, omitting `--max-model-bytes` uses 4,000,000,000; on an existing model it
preserves the saved smaller cap. An explicit `--model` overrides
`ALITA_LLM_PATH`. Both byte-limit options accept integers from 1 through
4,000,000,000.

The default per-file limit is 10 MiB. `/read` accepts one regular UTF-8 text
file, with or without a UTF-8 BOM. Binary data, invalid UTF-8, directories, and
oversized files are rejected. There is no directory recursion, network fetch,
or shell-command execution.

A failed atomic chat, teaching, or file import is not saved. Errors are printed
and the session remains available, but it eventually exits with a nonzero
status. Duplicate file reads and read-only commands such as `/stats` and
`/sources` do not rewrite the model.

The model path matters for privacy. Memories are persisted without encryption,
and the default `myBrainLLM.dat` is tracked by Git. The example path
`examples/alita-chat.dat` is ignored by this repository; still, do not commit
or share a model containing sensitive conversations or imported text.

A minimal low-level bigram example looks like this:

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
same sentence again gives its word transitions more weight. `train()` checks
the complete serialized model against `max_model_bytes` before retaining the
change.

Use `learn()` when text and memory entries must succeed or fail together:

```perl
$model->learn(
    texts => ['Mars has two moons.'],
    memories => [{
        kind   => 'teaching',
        prompt => 'How many moons does Mars have?',
        text   => 'Mars has two moons.',
    }],
);
$model->save();
```

The operation is atomic: invalid input or a model-cap violation leaves both the
text counts and memories unchanged. `memories()` returns a deep copy, so
changing the returned array or hashes cannot mutate the model.

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
