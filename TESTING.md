# Running the test suite

These tests use Perl's Test::More and are executed with the `prove` harness.

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
- The test `t/alita_conversation.t` spawns `alita.pl`, runs a short interactive session, and ensures a temporary `myBrainLLM.dat` is created and persisted across runs.
- It automatically sets `PERL5LIB` to include `lib/` so `TinyLLM` can be found.
- The test uses a temporary working directory, so it will not modify files in your repository.
