# TinyLLM examples

`digit_recognizer.pl` demonstrates TinyLLM's supervised classifier with the
28 x 28 grayscale images in `../digit-recognizer/`. `model_info.pl` inspects
any existing TinyLLM model without training or writing to it.

Run these commands from the project root.

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

The report includes the actual file size, text vocabulary and unique-transition
counts, serialized size of the current state, and classifier metadata. The two
sizes can differ after loading an older model or a copy at a new path. A
ten-digit model keeps 10 x 784 = 7,840 per-label feature counts plus 10 label
example counts; it does not retain the individual training images. The
verified model trained on 40,000 rows occupies 26,262 bytes (25.65 KiB).
