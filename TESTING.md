# Testing Alita

Run these commands from the project root.

## Automated tests

Run the entire Perl test suite:

```powershell
prove -lvr t
```

Run the TinyLLM API tests only:

```powershell
prove -lv t/tinyllm.t
```

Run the digit command-line tests only:

```powershell
prove -lv t/digit_recognizer.t
```

These tests build small synthetic CSV files, so they do not require the local
42,000-row digit dataset.

Run the interactive-agent persistence test only:

```powershell
prove -lv t/alita_conversation.t
```

The tests use temporary directories and do not modify the checked-in
`myBrainLLM.dat`.

## Syntax checks

```powershell
perl -Ilib -c lib/TinyLLM.pm
perl -Ilib -c alitaLLM.pl
perl -Ilib -c examples/digit_recognizer.pl
perl -Ilib -c examples/model_info.pl
podchecker lib/TinyLLM.pm
```

## Digit-example smoke test

This test requires the ignored local files `digit-recognizer/train.csv` and
`digit-recognizer/test.csv`.

The following command trains on 800 rows, validates on 200 held-out rows, and
writes its temporary model outside the repository:

```powershell
$model = Join-Path $env:TEMP 'tinyllm-digit-smoke.dat'
$predictions = "$model.csv"
perl examples/digit_recognizer.pl train --limit=1000 --validation=200 --model="$model" --overwrite
perl examples/digit_recognizer.pl evaluate --data="digit-recognizer\train.csv" --limit=200 --model="$model"
perl examples/digit_recognizer.pl predict --limit=10 --model="$model" --output="$predictions" --overwrite
perl examples/model_info.pl --model="$model" --json
```

The separate `evaluate` command reads the saved model without training or
saving it. Limiting evaluation to the first 200 rows reuses the holdout from
the preceding smoke-test training command; evaluating its 800 training rows
would give an optimistically biased accuracy.

Remove the two temporary files when the smoke test is complete:

```powershell
Remove-Item -LiteralPath $model, $predictions
```
