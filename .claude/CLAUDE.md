# Project instructions

## Naming conventions
- All folder names and unix paths must use kebab-case (e.g. `my-module`, not `MyModule` nor `my_module`).
- Exception: paths dictated by third-party software (e.g. `/opt/AdGuardHome/`) must not be renamed.

## Next steps log
At the end of each response, if the work session produced relevant next steps, update `docs/next-steps.md`.

Each entry must follow this format:
```
## YYYY-MM-DD — <objective>

### Next steps
- ...
```

Append new entries at the top of the file. Never overwrite the file — always prepend the new entry and preserve existing content below it. The file is gitignored and serves as a running working log.
