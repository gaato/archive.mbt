# gaato/zip

ZIP archives in pure MoonBit for Native, JS, Wasm and Wasm GC. Read and write
Store (0), Deflate (8) and Zstandard (93), read Deflate64 (9), edit archives in memory, or use
range readers and a writer over a caller-supplied sink. The API follows
MoonBit core's `archive/zip`.

## Install

```sh
moon add gaato/zip
```

Import `"gaato/zip"` in your `moon.pkg`.

## Usage

```mbt check
///|
test "create, read, edit and rewrite a ZIP" {
  let archive = @zip.Archive()
  archive.add("hello.txt", b"hello", compression=Zstandard)
  let bytes = @zip.write(archive)
  let decoded = @zip.read_all(
    bytes,
    limits=@zip.ReadLimits(
      max_package_bytes=1024 * 1024,
      max_entries=100,
      max_entry_uncompressed_bytes=1024 * 1024,
      max_total_uncompressed_bytes=4 * 1024 * 1024,
    ),
  )
  assert_eq(decoded.get("hello.txt"), Some(b"hello"[:]))
  assert_true(decoded.replace("hello.txt", b"updated"))
  assert_eq(
    @zip.read_all(@zip.write(decoded)).get("hello.txt"),
    Some(b"updated"[:]),
  )
}
```

`DirectoryReader::advance` returns `NeedRead(range)` or `Done(directory)`.
Supply exactly the requested range from the same immutable source. Listing
retains metadata, including encrypted entries and unknown methods, without
reading their payloads. `Directory::open_entry` rejects unsupported methods
and encryption before any read. Drive `EntryReader::step` with the requested
bytes and an output slice; take `last_produced()` after every successful step,
including `Done`. Output remains unverified until `Done` checks sizes and CRC.

`Writer` takes a synchronous byte sink. Use `add` for a complete file or
`begin_entry`, `write`, `end_entry` for chunks, then `finish`. Sink failures
propagate and poison the writer. `level` is the level the selected codec takes:
it is passed unchanged to gaato/deflate or gaato/zstd. With gaato/deflate 0.4.0,
Deflate levels 0 through 12 are available, including near-optimal levels 10–12.
`preserve=true` on
`write` reuses unchanged source records; a pristine archive is byte identical,
including an SFX prefix. Editing drops bytes outside the records.
Deflate64 is read-only: `write` (including `preserve=true`), `Writer::add` and
`Writer::begin_entry` reject it with `InvalidArgument`. A rejected writer
argument emits no bytes and leaves the writer ready for another entry.

## Limits and errors

Set `ReadLimits` for untrusted input: defaults allow up to the in-memory
Int32 capacity. `DirectoryLimits` bounds directory bytes and entry count;
`EntryReadLimits` bounds decoded output. Range offsets and lengths of entries
are 64-bit, including ZIP64 archives larger than 4 GiB. `max_output_bytes`
bounds the final buffer returned by `write`; it does not bound the model or
temporary encoded payloads. Cancellation is polled by `read_all`; range
readers are cancelled by stopping between steps.

Both readers scan the last **65,535 + 22 bytes** for EOCD records whose declared
comment fits in the file; an overrunning comment is rejected. **Tier 1** checks
all candidates ending exactly at EOF. A nonempty directory must start with
`PK\x01\x02` at `boundary - cd_size`, with a nonnegative archive start
`boundary - cd_size - cd_offset`; the boundary is the classic EOCD or resolved
ZIP64 end record. An empty directory (zero entries and size) needs no prefix
gap: `cd_offset == boundary`. Exactly one valid candidate is used; multiple
valid candidates raise `Corrupt` (APPNOTE 4.3.1: "MUST have only one"). If all
fail, the earliest candidate's error is raised, without trying tier 2.
**Tier 2**, only if none end at EOF, tries fitting candidates from last to
earliest and uses the first passing the same checks, tolerating trailing data.

The shared engine tries a valid, agreeing ZIP64 locator/record before classic,
including during the signature probes. If the selected ZIP64 directory fails
full parsing, it retries classic with the SFX gap and the same structural
probe; if both fail, it reports the classic error. It does not reopen the EOCD
search after full parsing fails.
Entry and byte limits apply only after selection; directory limits do not cap
speculative probes or temporary memory. Bound transport work separately or
cancel between range steps. A uniquely plausible forgery or two ZIP64/classic
readings can still be ambiguous in intent; use a trusted source boundary or
external authentication when that distinction matters.

The [ten-reader survey comparison](https://github.com/gaato/archive.mbt/blob/main/docs/upstream.md#eocd-survey-comparison)
records the tested versions and warnings. In this compact table, `R` means
real entries, `0` an empty decoy, and `E` rejection; warning details and the
7-Zip header-error/listing distinction are in the full table. .NET and core
are inferred from the supplied sources; the other rows were replayed.

| Reader | a normal | b garbage | c zeros | d decoy | e decoy + garbage | f SFX | f2 adjusted | g truncated |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gaato/zip, both APIs | R | R | R | R | R | R | R | E |
| Python / unzip / libarchive | R | R | R | 0 | 0 | R | R | R |
| Go / Rust zip | R | R | R | 0 | 0 | R | R | E |
| 7-Zip | R | R | R | R | R | E | R | E |
| Java | R | R | R | 0 | R | R | R | E |
| .NET | R | R | R | 0 | 0 | E | R | E |
| moonbitlang/core | R | E | E | E | E | E | R | E |
| minizip-ng CLI | R | R | R | E | E | R | R | R |

Failures raise `ZipError(kind, message)`. Branch on `kind`: container errors
include invalid records, size or CRC mismatch, unsupported features, resource
limits and cancellation. `Codec(kind)` preserves the compression codec's
`gaato/codec.ErrorKind`, including corrupt, truncated and trailing data.
Shared or overlapping local records are refused. A listing checks declared
extents; opening checks the actual header and descriptor against the next
record. Error messages are diagnostic text.

This package performs no filesystem extraction. Path safety (`../`, absolute
paths and symlinks) is the caller's responsibility. Encryption and split
archives are unsupported. Wrapped classic entry counts above
65,535 without ZIP64 are unsupported. Names must be UTF-8. Zstandard ZIPs
need readers with method 93 support.

## Links

- [Changelog](https://github.com/gaato/archive.mbt/blob/main/zip/CHANGELOG.md)
- [Resource bounds](https://github.com/gaato/archive.mbt/blob/main/zip/RESOURCE_BOUNDS.md)
- [Test coverage](https://github.com/gaato/archive.mbt/blob/main/zip/TEST_COVERAGE.md)
- [Upstream and port decisions](https://github.com/gaato/archive.mbt/blob/main/docs/upstream.md)

## License

Apache-2.0. Derived from MoonBit core's `archive/zip`, copyright 2026
International Digital Economy Academy. See the repository's
[LICENSE](https://github.com/gaato/archive.mbt/blob/main/LICENSE) and
[NOTICE](https://github.com/gaato/archive.mbt/blob/main/NOTICE).
