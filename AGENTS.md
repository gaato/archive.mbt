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
- A module README has two readers: a person deciding from the first screen
  on mooncakes.io, and a coding agent that reads the raw file in a user's
  `.mooncakes/` and copies its examples. So the first example runs as copied
  (Install adds every module it uses, and the imports are shown), and what a
  caller cannot read off the code is written out: defaults and limits as a
  table (setting, default, what happens past it), errors as a table (kind,
  when, what the caller does), and what the module deliberately does not do,
  because an agent invents what a README leaves out.
- Give a reason in the README only when it changes how a caller writes code,
  such as a setting with no default or a check that cannot be turned off;
  other rationale goes to `docs/`. Overviews and design discussion cost an
  agent context without changing what it writes.
- Keep facts that go stale out of the README: upstream and toolchain
  versions, counts of cases or files, dates, "now", "latest", "not yet". Put
  them in a ledger, the CHANGELOG or a benchmark page and link there; a reader
  applies a stale fact without noticing it is stale.
- Name sections and terms as the other gaato modules do (Install, Usage,
  Limits and defaults, Errors, Not here, Checked against, Links, License), so
  a reader who learned one module reads the next one correctly.
- Write nothing addressed to an AI in a README: an agent reading a
  dependency's README would take it as an instruction.
