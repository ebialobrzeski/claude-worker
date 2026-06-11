# Security audit

Perform a read-and-report security review of this repository. This task is
**report only** — do not change code unless a fix is trivial and clearly safe.

Look for:
1. Hardcoded secrets, API keys, tokens, or credentials.
2. Injection risks — SQL, shell/command, path traversal, template injection.
3. Unsafe deserialization or use of `eval`/`exec` on untrusted input.
4. Missing input validation on external/user-facing boundaries.
5. Insecure defaults (permissive CORS, disabled TLS verification, weak crypto).
6. Dependencies with known-vulnerable patterns of use.

Produce a findings report grouped by severity (Critical / High / Medium /
Low), each with file:line, a short explanation, and a recommended fix. If no
issues are found in a category, say so explicitly.
