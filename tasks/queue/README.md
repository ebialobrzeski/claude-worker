# tasks/queue

Drop `.md` task files into this directory to trigger Claude Code runs.

Each file's full contents become the prompt passed to Claude. The worker
scans this directory every `$POLL_INTERVAL` seconds (default 30) and
processes files in **alphabetical order** — prefix names with `01_`, `02_`,
etc. to enforce sequencing.

After a run the file is moved out of the queue:

- success → `tasks/done/TIMESTAMP_name.md`
- failure → `tasks/failed/TIMESTAMP_name.md`

Queue a task by copying a file here, or use the host helper:

```bash
./dispatch.sh tasks/examples/fix_tests.md
./dispatch.sh "Refactor auth module to use JWT" refactor_auth
```

This README is kept in git; queued task files are gitignored.
