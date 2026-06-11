# Add missing docstrings

Add clear, accurate docstrings/doc comments to public functions, classes,
and modules that are currently undocumented.

Steps:
1. Identify the primary language(s) in the repo and the idiomatic doc
   format (Python docstrings, JSDoc, GoDoc, rustdoc, etc.).
2. Find public/exported symbols lacking documentation.
3. Write concise docs describing purpose, parameters, return values, and any
   notable side effects or errors. Match the existing style in the file.
4. Do not change any behavior — documentation only.

Skip private/internal helpers unless their intent is non-obvious. Prefer
fewer, high-quality docstrings over blanket coverage.
