# Fix failing tests

Run the project's test suite and fix any failing tests.

Steps:
1. Detect the test runner (e.g. `pytest`, `npm test`, `go test`, `cargo test`)
   by inspecting the repo's config files.
2. Run the full suite and capture the failures.
3. For each failure, determine whether the bug is in the test or in the
   code under test, then fix the root cause — do not delete or skip tests
   to make them pass.
4. Re-run the suite until it is green.
5. Summarize what was failing and what you changed.

Do not modify unrelated code. Keep the diff focused on making the tests pass.
