# TinyLLM examples

`conversation.pl` demonstrates local teaching, conversation recall, and one
explicitly ingested knowledge file. `digit_recognizer.pl` demonstrates
TinyLLM's supervised classifier with the 28 x 28 grayscale images in
`../digit-recognizer/`. `model_info.pl` inspects any existing TinyLLM model
without training or writing to it.

Run these commands from the project root.

## Conversation, teaching, and explicit files

First run the self-contained library example. It teaches an identity, recalls
the user's favorite constellation, imports the bundled fictional Lantern
workshop notes, answers a city question, and saves an ignored demo model:

```powershell
perl examples/conversation.pl
```

Use `perl examples/conversation.pl --help` to select a model, a different
UTF-8 knowledge file, or a smaller model cap. Then start the interactive
agent with another ignored model:

```powershell
perl alitaLLM.pl --model=examples/alita-chat.dat
```

At its prompt, ordinary lines chat with the agent. This walkthrough teaches a
fact, asks for it, imports the project README, and inspects the saved state:

```text
/teach What color is the lab door? => The lab door is blue.
What color is the lab door?
/read "README.md"
What is the default model cap?
Tell me more.
/sources
/stats
/save
/help
/quit
```

The agent recalls taught answers, relevant source excerpts, or recent
conversation before learning the current question. When nothing matches, it
returns readable guidance rather than stochastic generated text. The same
inputs still train TinyLLM's separate one-word-context bigram API. These small
local mechanisms are not transformer reasoning or a promise of reliable
free-form document question answering. Program input and output use UTF-8;
whitespace-only input is skipped.

Exact taught questions return their saved answers. File recall uses
conservative keyword overlap; a multi-keyword question must share at least two
meaningful words, so ask with terms found in the source. Follow-ups such as
“Tell me more” reuse the preceding question to search teaching and file
memories. Clear personal facts such as “My favorite constellation is Orion”
are acknowledged and can be recalled by a later question. To import a
different file whose path contains spaces, quote it:

```text
/read "C:\path with spaces\notes.txt"
```

`/read` accepts only the one regular UTF-8 text file explicitly named by the
user. UTF-8 BOMs are supported; binary data, invalid UTF-8, directories, and
oversized files are rejected. File content is stored as data and is never
executed as a command. The program performs no recursion, network fetch, or
shell execution.

The default model cap is 4,000,000,000 bytes (decimal 4 GB, about 3.73 GiB),
and the default per-file cap is 10 MiB. Configure smaller limits when useful:

```powershell
perl alitaLLM.pl --model="C:\path with spaces\brain.dat" --max-model-bytes=50000000 --max-file-bytes=1048576
```

The model cap applies to the complete serialized model, not Perl RAM or total
temporary/backup disk use. Each checked update serializes the complete
prospective snapshot, so update cost grows with model size and memory can run
out before the 4 GB storage ceiling. The cap does not make TinyLLM a 4 GB
neural model. Learned turns, teachings, and successful file reads are saved
automatically.

Failed atomic learning is not saved. Duplicate file imports and read-only
commands do not rewrite the model. An explicit `--model` option overrides
`ALITA_LLM_PATH`.

Memories, taught answers, imported excerpts, and source paths are stored as
recoverable text in the model, not encrypted. The default `myBrainLLM.dat` is
tracked by Git, while `examples/*.dat` is ignored. Use a private ignored model
such as `examples/alita-chat.dat` for personal knowledge, and do not commit or
share sensitive model data.

## Train and predict

Run a small training and validation pass:

```powershell
perl examples/digit_recognizer.pl train --limit=5000 --validation=1000 --overwrite
```

After validation succeeds, the command reports the saved model's byte and KiB
size.

Then create a short prediction file as a smoke test:

```powershell
perl examples/digit_recognizer.pl predict --limit=100 --overwrite
```

The training command reserves the first 1,000 of the 5,000 considered rows and
trains on the remaining 4,000. This split is not randomized or stratified.

Defaults:

- training data: `digit-recognizer/train.csv`
- test data: `digit-recognizer/test.csv`
- model: `examples/tinyllm-digits.dat`
- predictions: `examples/digit-submission.csv`
- pixel activation threshold: 128

Use `perl examples/digit_recognizer.pl help` for every option. The root
`README.md` explains the algorithm, library API, and full-data commands.

## Evaluate without training

`evaluate` reads a labeled CSV and reports overall and per-digit accuracy. It
does not train or save the model. For a model trained with the default first
2,000 rows held out:

```powershell
perl examples/digit_recognizer.pl evaluate --data="digit-recognizer\train.csv" --model="examples\tinyllm-digits.dat" --limit=2000
```

Evaluating images that were used to train the model will overestimate accuracy
on new data. A prediction's confidence is normalized within the
naive-independence model and is not calibrated accuracy.

## Add new labeled data

To add a CSV containing new labeled rows to the default saved model:

```powershell
perl examples/digit_recognizer.pl train --data="C:\path with spaces\new-digits.csv" --model="examples\tinyllm-digits.dat" --validation=0 --resume
```

The new file must use the same `label,pixel0,...,pixel783` columns and the same
pixel threshold as the existing model. `--resume` is additive, so do not replay
rows that are already represented unless you intend to give them more weight.
Use `--overwrite` instead when you want to train a fresh model.

When `--resume` is used without `--threshold`, the saved classifier's threshold
is inherited. An explicit threshold must match. If you originally chose a
custom model path, pass that same quoted `--model` path when resuming.

## Inspect a model

`model_info.pl` requires an existing model and never modifies it. Its default
is `myBrainLLM.dat`; choose another model with `--model` and request
machine-readable output with `--json`:

```powershell
perl examples/model_info.pl
perl examples/model_info.pl --model="examples\tinyllm-digits.dat"
perl examples/model_info.pl --model="C:\path with spaces\tinyllm.dat" --json
```

The report includes the actual file size, current serialized size and cap,
memory/source counts, text vocabulary and unique-transition counts, and
classifier metadata. The two sizes can differ after loading an older model or
a copy at a new path. A ten-digit model keeps 10 x 784 = 7,840 per-label
feature counts plus 10 label example counts; it does not retain the individual
training images. The verified model trained on 40,000 rows occupies 26,262
bytes (25.65 KiB).
