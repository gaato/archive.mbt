# Upstream provenance and port decisions

The source is `moonbitlang/core` **25a579771**, `archive/zip/`, read from
`origin/main`. This port retains the upstream Apache-2.0 notices and adds an
origin path, commit and modified marker to each of the 21 copied files and
the codec adapter extracted from `reader.mbt`.
`LICENSE`, `NOTICE` and `scripts/gates.mbtx` track that attribution. The
upstream test files include the four requested suites and the additional
declared-size, error-trait and byte-buffer suites present at this commit:
85 upstream tests, before this module's additions.

## Checking upstream fixes

Once a month, inspect changes under `archive/zip/` since 25a579771 in the
upstream repository. Review parser, range-reader, size-limit and writer fixes
against this port, retaining their original notices. Update the origin markers,
this document and the attribution gate when importing another revision, so
future comparisons start from the exact source that was incorporated. Run
the gates and external interoperability checks after applying a fix because
changes in record validation can alter both reads and preserved rewrites.
No upstream issue or pull request is opened by this implementation task.

## Intentional differences from core

- `gaato/deflate@0.4.0`, `gaato/zstd@0.5.1`, `gaato/crc@0.1.0`,
  `gaato/codec@0.1.1` and `gaato/codec_bytes@0.1.2` replace experimental
  core flate/checksum dependencies. Entry readers hold `&@codec_bytes.Decode`;
  streaming writers hold `&@codec_bytes.Encode`.
- Compression method 93 is `Zstandard`, readable and writable. Its generated
  headers declare ZIP version 6.3. Store and Deflate retain IDs 0 and 8.
- Compression method 9 is `Deflate64`, read through
  `gaato/deflate/deflate64.Decoder(until=EndOfMember)` behind the same
  `&@codec_bytes.Decode` path as the other codecs. It has a 64 KiB history
  window. It is read-only: `write`, including preserved writes, and both
  streaming entry-start APIs reject it with `InvalidArgument` before output.
- `InvalidDeflate` is replaced by `Codec(@codec.ErrorKind)`. Codec truncation
  and trailing data now remain `Codec(Truncated)` and `Codec(TrailingData)`;
  record/container truncation stays `Truncated`. Codec diagnostic messages
  consequently differ. Cancellation remains ZIP's `Cancelled`.
- `fast_store` is absent from both `write` and `Writer`.
- The level argument goes unchanged to the selected codec. As clarified by
  the user, ZIP imposes no level range or clamping. Deflate 0.4.0 adds levels
  10 through 12; tests cover forwarding them through whole and streaming
  writers, with a corpus whose level-12 encoding differs from level 9.
  Python zipfile, unzip and 7-Zip validate level-12 output on all targets.
  The same level argument is passed to Zstandard's encoder.
- A gap between recorded directory offsets and its physical end is added
  to the directory and local offsets, like Python's `zipfile` concat
  adjustment. SFX classic and standard ZIP64 archives work with both APIs,
  including a maximum-length comment. Pristine preserving writes retain
  the prefix; edited writes drop it, as core does for bytes outside records.
- **Inherited from core:** its backward EOCD scan could select an end-record
  decoy inside the real comment. The tiered selection rule below replaces
  backward-first and earliest-first selection. Exactly 65,535 classic
  entries remain valid; locators hidden by a maximum comment are still probed.
- **Inherited from core:** `read_all` rejected a central-directory digital
  signature accepted by the range reader. Both now accept and skip the framed
  `PK\x05\x05`, 16-bit size and data record inside the declared directory size,
  per APPNOTE 4.3.13. This checks framing, not a cryptographic signature.
  Pristine preserving writes retain it; edited writes rebuild the directory
  and omit it. Extra central entry records still fail, so wrapped classic
  counts stay rejected; both APIs now classify that extra-record case as
  `InvalidSignature`.
- Local encoded extents are checked before any entry is eagerly decoded.
  Shared local headers, overlapping payloads, headers and descriptors are
  rejected with `UnsupportedFeature`. Directory listings reject duplicate
  offsets and overlapping minimum declared extents. On open, the next local
  header bounds the actual variable header, payload and descriptor, so the
  range reader refuses overlaps it could not establish from metadata alone.
- Compression buffers now belong to the selected codec. Whole-file writes
  allocate an encoder per compressed member. Chunked writers lazily cache one
  encoder per used method, reset it between entries, and share one 64 KiB
  output buffer across methods. Finish or a failed sink releases the caches.
  Compressed output is copied into immutable chunks before calling the sink:
  even a sink retaining a full 64 KiB `view.to_owned()` cannot alias scratch
  that a later step or entry overwrites.
  The eager decoder writes directly into growing owned output views without
  a temporary Bytes copy per 4 KiB chunk. No timing claim is made.
- Known-size chunked headers reserve ZIP64 using the selected codec's
  `compress_bound`, rather than core's DEFLATE-specific heuristic, because
  the replacement encoders have different worst-case sizes. This is tested
  near the 32-bit sentinel without allocating a large payload. Store uses its
  exact input size, so it can keep classic headers closer to that sentinel.
- Core's newer `Buffer(capacity=...)` spelling is adapted to the pinned
  toolchain's `Buffer(size_hint=...)`; this has no API or format effect.

## Decisions and limits relative to the design

Both APIs use one selection engine: `DirectoryReader`; `read_all` drives it
over the caller's in-memory bytes instead of implementing a second policy.

1. Collect EOCD signatures in the last **65,535 + 22 bytes** whose full fixed
   record and declared comment fit in the file: `off + 22 + len <= size`.
   A comment-length overrun is rejected, never shortened to the available data.
2. **Tier 1:** if any candidate's comment ends exactly at EOF, validate every
   such candidate. A nonempty directory needs `PK\x01\x02` at
   `boundary - cd_size` and a nonnegative archive start
   `boundary - cd_size - cd_offset`. Here `boundary` is the EOCD offset for
   classic ZIP or the ZIP64 end-record offset after ZIP64 resolution. A
   directory with zero entries and size zero is valid only with no prefix gap:
   `cd_offset == boundary`. These are selection probes, not full entry parsing.
   Exactly one valid candidate is selected. More than one raises `Corrupt`
   with "more than one end of central directory record", citing
   [APPNOTE 6.3.10, 4.3.1](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT):
   "MUST have only one". If none validate, report the earliest candidate's
   error. Tier 1 never falls through to tier 2, even if all candidates fail.
3. **Tier 2:** only when no candidate reaches EOF, visit complete candidates
   from last to earliest and select the first passing the same probes. This
   tolerates trailing garbage or zeros within the bounded search window.
4. For each candidate, validate the ZIP64 locator and record, including equality
   of all non-sentinel classic counts, size and offset. Check the locator's own
   target before the ordinary fixed SFX location. Try the agreeing ZIP64
   directory. If its selection probe or subsequent structure, counts, signature
   framing or extents fail,
   discard that attempt and try classic with the prefix gap the offsets demand.
   The classic retry must pass the same central-header signature or empty-gap
   probe, including when it follows a post-selection ZIP64 parsing failure.
   A record signature without a valid agreeing record also goes to classic.
   If both readings fail, report the **classic attempt's error**, including
   when its sentinel fields make classic impossible. Transport response errors
   and cancellation remain final rather than reinterpreting the input.
5. Fully parse the selected directory and apply entry and byte limits to the
   reading finally chosen. Limits do not participate in EOCD choice or the ZIP64/classic
   decision. A valid ZIP64 directory that exceeds a caller limit remains the
   chosen reading and reports that limit; it does not switch to classic.

Tier 1 refuses two plausible EOF-reaching interpretations, including an empty
decoy whose offset was adjusted to remove its prefix gap. Earlier regression
archives with that shape are retained with the new `Corrupt` expectation.
Selection cannot establish intended-source identity: a uniquely plausible
forgery can still claim surrounding bytes as a comment or prefix, tier 2
deliberately prefers the last valid reading, and a structurally valid ZIP64
reading wins over classic. A signature-valid candidate may subsequently fail
full entry parsing; that does not reopen the EOCD search. Callers requiring
identity need a trusted container boundary or authentication outside this
parser. Limits protect the chosen result, not speculative probes or metadata;
the transport/caller must bound I/O work or cancel between range requests.

### EOCD survey comparison

The supplied 2026-11-17 survey uses APPNOTE **6.3.10** and the eight files now
retained under `zip/testdata/eocd-survey/`. `R` means the real two entries were
read/listed, `0` means the decoy was accepted as an empty archive, and `E`
means rejection. `W` adds a warning; it still exposes the real entries. The
7-Zip `E/list` cell lists entries but reports a header error. This is a frozen
matrix, not a promise about future reader versions.

| Reader | a normal | b garbage (100 B) | c zeros (100 B) | d comment decoy | e decoy + garbage | f SFX unadjusted | f2 SFX adjusted | g truncated comment |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gaato/zip, both APIs | R | R | R | R | R | R | R | E |
| Python 3.13.16 | R | R | R | 0 | 0 | R | R | R |
| Info-ZIP unzip 6.00 | R | R | R | 0/W | 0/W | R/W | R | R/W |
| 7-Zip 26.04 | R | R/W | R/W | R | R/W | E | R | E/list |
| libarchive 3.8.10 (bsdtar) | R | R | R | 0 | 0 | R | R | R |
| Go archive/zip | R | R | R | 0 | 0 | R | R | E |
| Rust zip 2.6.1 / surveyed main 9.6.1 | R | R | R | 0 | 0 | R | R | E |
| Java OpenJDK 25.0.5 | R | R | R | 0 | R | R | R | E |
| .NET ZipArchive (source inspection) | R | R | R | 0 | 0 | E | R | E |
| minizip-ng 4.2.2 CLI | R | R | R | E | E | R | R | R |
| moonbitlang/core 25a579771 (source inspection) | R | E | E | E | E | E | R | E |

The runnable survey tools were replayed for the table; .NET and core rows are
inferred from the supplied source snapshots. In particular, .NET uses the
recorded central offset without an SFX gap and checks that the comment fits;
core requires an EOF-reaching comment and exact directory adjacency. Java's
extra signature checks apply when the comment does not end at EOF, which
explains its different d/e results. minizip-ng's CLI reports a first-entry
error for the empty decoy; that is not evidence of recovering the real entries.
The gaato row is asserted with names and contents on both APIs, plus separate
tests for two valid EOF-reaching records, tier priority and earliest errors.

The initial port deferred Deflate64 until its decoder was published. The
0.4.0 dependency now enables the approved read-only method-9 design; other
unknown method numbers still raise `UnsupportedCompression(id)` before data
reads. A decoded Deflate64 archive must have those entries removed or copied
into new writable-method entries before it can be serialized.

ZIP64 SFX adjustment follows Python's ordinary fixed 56-byte ZIP64 end record.
Unprefixed ZIP64 end records with an extensible sector retain core's support.
An SFX prefix combined with an extensible ZIP64 end record is not supported;
neither is a wrapped classic count above 65,535 without ZIP64. Encryption,
split archives and non-UTF-8 names retain core's restrictions. Path safety and
filesystem extraction remain the caller's responsibility.

The library is an archive layer, rather than a byte-stream codec: its ZIP
state, sizes, CRC, cancellation and container limits stay here, above the
codec contracts. No tar or extraction tool is included.

## Interoperability fixtures

`scripts/gen_interop.mbtx` reproduces the archives in `zip/testdata`, fixes
timestamps and uses isolated Python. `SHA256SUMS` identifies each archive;
`PRODUCERS.txt` records versions, `7z i` and capability skips. Embedded byte
fixtures in `interop_vectors_test.mbt` let all targets read the same archives
without filesystem access. `--check` verifies the hashes and embedded source;
regeneration uses the installed producer versions, which can change bytes.

`scripts/interop.mbtx` tests twelve produced archives per target: Store,
Deflate, Zstandard and Deflate at level 12, each with whole-buffer, classic
chunked and ZIP64 chunked writing. Python calls
`testzip()` and compares exact contents; unzip and 7z test archive integrity.
No archive is extracted. All temporary files are under `_build/interop-*`.
The gates compare the bytes of the other targets against Native's files.

The local Python 3.14 supports method 93. Info-ZIP unzip does not, so its three
Zstandard checks report an explicit unsupported-method skip. The local 7-Zip
can decode these ZIPs but `7z i` advertises no Zstandard encoder; generation
records that skip. Python supplies the independent Zstandard fixture.

7-Zip 26.04 supplies three pinned method-9 archives: a small Deflate64 entry,
a 147,456-byte entry, and that entry together with a stored entry. The large
payload repeats a seeded 49,152-byte noise block three times. An independent
Huffman/token walker in the fixture generator verifies the compressed member
actually uses distance **49,152**, beyond ordinary Deflate's 32 KiB history;
`--check` repeats this structural check along with the SHA-256 checks. During
generation, 7-Zip tests integrity and returns exact contents through stdout.
Both APIs compare the generated expected data on every target. CPython
zipfile cannot decode method 9, so those three fixtures use 7-Zip and their
known inputs instead of a Python content oracle.

`scripts/gen_python_oracles.mbtx` additionally records CPython `zipfile`'s
ordered entry names and exact contents in `zip/testdata/python-oracles.json`.
The generated `python_oracles_test.mbt` compares both APIs with those answers
on all four targets, with no Python process during `moon test`. Its catalog
covers every finite non-adversarial archive constant (the five upstream ZIPs
and the empty archive), the six Python-readable external archives and all
twelve writer outputs, and the five ordinary survey cases a/b/c/f/f2:
29 archives. The explicitly lying ZIP64 size fixture and crafted
decoy/malformed regressions are adversarial and intentionally do not use
Python as their oracle; the >4 GiB synthetic range source is not a finite
archive fixture. The generator checks the constant catalog, source hashes
and generated tests for drift. Python runs only when rebuilding oracle data;
`--check` uses hashlib without invoking zipfile.
