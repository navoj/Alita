Alita
=====

Alita is a Perl script exploring using evolutionary algorithms to write Perl scripts for a goal. 

## Overview

Alita includes interactive and evolutionary components to learn, evolve, and generate responses or scripts. The project includes various components such as:

- `alita.pl`: An interactive learning program that builds a database by communicating with users. It uses "brain" data files (e.g., `myBrain32.dat`, `myBrain64.dat`) to store memories and responses.
- `alitaLLM.pl`: An LLM-integrated interactive agent that uses the `TinyLLM` module to train on conversational input from STDIN and generate replies, persisting the model to `myBrainLLM.dat`.
- `archive/`: Contains older versions and experiments like `evolver.pl`, `life.pl`, `lifeform.pl`, and brain data files (`myBrain.dat`, `myBrain64.dat`, `myBrain_AIX_Format.dat`, etc.).
- `lib/TinyLLM.pm`: A minimal bigram-based language model implementation used for conversation and text generation.
- `form_fitter_v1p0/`: Form fitter experiments and data generation scripts, including `form_fit.pl`, which fits a data set by randomly forming and testing functions and calculating Mean Squared Error (MSE).
- `unhash_project/`: Projects related to machine learning, training data generation, and hash reversal (e.g., `sha256.pl` for computing SHA-256 hashes using `Digest::SHA`).
- `t/alita_conversation.t`: Test suite for the LLM conversational agent using `Test::More` and `IPC::Open3`.

## How to Use

### Prerequisites
Ensure you have Perl installed on your system. The project requires standard Perl modules such as `Storable`, `IO::Scalar`, `Term::ReadKey`, `Test::More`, `IPC::Open3`, `File::Temp`, `File::Spec`, `Cwd`, `POSIX`, `Time::HiRes`, and `Digest::SHA`.

### Running the Interactive Agent (`alita.pl`)
- Execute the main script using Perl with a brain type argument (32 or 64):
  ```
  perl alita.pl [32|64]
  ```
- The script will attempt to load `myBrain32.dat` or `myBrain64.dat`. If the brain file exists, it greets you as "Alita" and loads memories. If not, it asks "Who am I?".
- You can interact by typing inputs. If the input matches a known memory key, it evaluates and prints the stored response. If not, it asks for a response and stores it.
- Type `quit` to save memories to `myBrain.dat` and exit.
- Type `simple eval...` to perform simple Perl evaluations.
- Type `alitabraintweak` to add new key-value pairs to the memory.

### Running the LLM-integrated Agent (`alitaLLM.pl`)
- Execute the LLM script using Perl:
  ```
  perl alitaLLM.pl
  ```
- You can also specify a custom model path using the `--model=...` argument or the `ALITA_LLM_PATH` environment variable:
  ```
  perl alitaLLM.pl --model=myCustomBrainLLM.dat
  ```
- The script reads conversational input from STDIN, trains the `TinyLLM` model on the input, and emits a generated reply.
- The model is persisted to `myBrainLLM.dat` (or the custom path specified) on normal exit or when interrupted (Ctrl+C).

### Running Form Fitter Experiments
- The `form_fitter_v1p0/form_fit.pl` script fits a data set by randomly forming and testing functions. It reads a data file, calculates Mean Squared Error (MSE), and attempts to build functions using operators and constants.

### Running Hash/ML Projects
- The `unhash_project/` directory contains scripts related to machine learning, training data generation, and hash reversal. For example, `unhash_project/sha256.pl` computes SHA-256 hashes of phrases using the `Digest::SHA` module.

## Running the Test Suite

These tests use Perl's `Test::More` and are executed with the `prove` harness.

Common commands to run from the project root:

- Run all tests verbosely with recursion into `t/`:
  ```
  prove -lvr t
  ```

- Run a single test file:
  ```
  prove -lvr t/alita_conversation.t
  ```

- Or, run directly with Perl:
  ```
  perl t/alita_conversation.t
  ```

Notes:
- The test `t/alita_conversation.t` spawns `alitaLLM.pl`, runs a short interactive session, and ensures a temporary `myBrainLLM.dat` is created and persisted across runs.
- It automatically sets `PERL5LIB` to include `lib/` so `TinyLLM` can be found.
- The test uses a temporary working directory, so it will not modify files in your repository.

## License

This project is licensed under the GNU General Public License v3.0. Please refer to the `LICENSE` file for details.
