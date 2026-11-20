# Agent notes

## Documentation

- A published module's `README.md` is a symbolic link to its
  `src/overview.mbt.md`, and mooncakes.io renders it as the module page.
  Keep its examples in `mbt check` fences: the file compiles with the
  package's tests, so a stale example fails `moon check` instead of
  misleading a reader.
- Run `moon run scripts/docs_audit.mbtx --self-test` after changing docs or
  public declarations. `scripts/docs_audit.mbtx` is identical in every gaato
  MoonBit repository: copy it from gaato/discord.mbt rather than editing it
  here, and put repository differences in `scripts/docs_audit.json` and
  `scripts/docs_audit.allow`.
- A module README is also read raw by coding agents in a user's
  `.mooncakes/`. They copy its examples, take every sentence literally, fill
  what it leaves out with guesses, and read the published text until the next
  release, while the modules it might mention change and get renamed.
