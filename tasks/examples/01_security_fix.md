# Fix one security flaw

Scan this repository for security vulnerabilities. Focus on:
1. Shell injection / command injection (untrusted input passed to eval, exec, or shell commands)
2. Hardcoded secrets or tokens
3. Path traversal vulnerabilities
4. Insecure defaults (disabled TLS, permissive CORS, weak crypto)

Pick the single highest-severity flaw you find, fix it, and explain what
you changed and why. If no real vulnerability exists, say so explicitly and
make no changes.

Do not fix more than one issue — one well-understood fix is better than
several rushed ones.
