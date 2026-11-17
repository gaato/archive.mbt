# Test coverage

The port includes all 85 upstream tests from the seven test files at
25a579771, compiled README examples, generated external fixtures and new
regressions in `src/methods_wbtest.mbt`, `src/zip64_review_wbtest.mbt` and
`src/reuse_wbtest.mbt`, `src/review2_wbtest.mbt`, `src/review3_wbtest.mbt` and
`src/eocd_selection_wbtest.mbt` (the eight survey cases, ambiguity, tier priority
and earliest errors on both APIs, plus the post-selection classic-signature
counterexample). The prefix-decoy regression also covers a successful classic
retry after the selected ZIP64 directory fails full parsing.
No timing benchmarks are run. `src/python_oracles_test.mbt` additionally checks
both APIs against generated Python entry-name/content data for all 29 finite
Python-readable fixture and interop archives, without Python at test time.
The three pinned 7-Zip Deflate64 fixtures use their known inputs instead
(Python has no method-9 decoder). They cover a 147,456-byte entry with a
verified 49,152-byte match distance, a stored/Deflate64 mix, eager reads and
small-output range reads. `src/deflate64_wbtest.mbt` checks write rejection,
writer recovery and levels 10–12, including a level-12/level-9 difference;
the external interop checks accept level-12 writes with Python and unzip.

`scripts/coverage_report.mbtx` is adapted from codecs.mbt. It runs Native
instrumentation, clears stale counters/maps and checks exact uncovered-line
budgets in this ledger. Scope is the production files directly under `src`;
test sources and the repository-only interop executable are excluded.

All four backends run identical tests. The mutation test performs 3,600 seeded
byte changes/truncations over Store, Deflate and Zstandard archives, driving
both eager and range readers. Only typed ZIP errors are accepted; unexpected
exceptions and aborts fail. Successful eager reads verify CRC and rewrite.
This is deterministic fuzz regression coverage, not exhaustive fuzzing.

The Range suite includes a synthetic source beyond 4 GiB, without allocating
the payload. Tests cover declared and actual limits, cancellation, descriptors,
ZIP64 extra fields, byte-preserving rewrites, encrypted/unknown method listing,
writer state, sink errors, SFX, shared extents and codec category preservation.

## Accepted uncovered

Budgets must match the measured count exactly. Target-only branches are
executed on their own backends. Defensive arms and testable gaps are identified
separately below; an uncovered line is not evidence of a verified contract.

| File | Budget | Reason |
| --- | --- | --- |
| src/codecs.mbt | 8 | Two Store factory aborts are unreachable from the dispatchers, which handle Store directly; the helper's Store copy arm is likewise not used by production. NeedMoreInput at end=true is defensive: the pinned codecs raise Truncated instead. The three second-pass error/size checks require a deterministic codec to change its result after reset; these are defensive. |
| src/conversion.mbt | 2 | Negative Int32-to-u32/u64 conversions are defensive for internal callers, which supply validated nonnegative offsets and sizes; not yet tested directly. |
| src/directory_reader.mbt | 5 | The Failed dispatch arm is bypassed by the public latch. Not yet tested: a missing locator signature forced by a sentinel, conflicting classic fields in a well-formed physical SFX fallback record, a selected count beyond intrinsic Int32 array capacity, and a signature-valid selected directory whose count cannot fit its size. The shared engine's ZIP64-directory failure/classic retry and post-selection limits are covered by review3 regressions. |
| src/entry_reader.mbt | 7 | Failed dispatch is bypassed by the public latch; UInt64 decoded overflow cannot be reached with practical output; NeedMoreInput at the last byte is defensive for codecs that raise at end=true. Not yet tested: an empty local name, an empty compressed payload with a nonzero decoded declaration, a compressed member producing too little output, and a descriptor crossing the next record. |
| src/reader.mbt | 5 | The raw local-offset guard is defensive after the shared selection engine validated the same immutable metadata. The three-line final cumulative-output check is defensive after per-entry actual-output checks. Not yet tested: the exact overlap guard reached through variable local-header or descriptor extents that were not already rejected by the metadata minimum-extent check. |
| src/reader_zip64.mbt | 2 | Incomplete ZIP64 fixed headers after checked record bounds are unreachable through the public engine, which requests exactly 56 bytes and rejects short range responses before parsing. The old separate eager ZIP64-selection adapter was removed. |
| src/stream_writer.mbt | 1 | Wrapping an encoder error is defensive: the pinned encoders receive no dictionary and valid actions/parameters and do not fail under that use. Sink failures are tested independently and propagate unchanged. |
| src/writer.mbt | 12 | Negative output count, u16 overflow and malformed preserved templates are defensive behind validated internal records. The helper's Store branch is bypassed by the archive dispatcher. Not yet tested: patching a preserved central record that encodes its local offset in a ZIP64 extra field (three lines). |

Native measurement on 2026-11-17: **1153/1195 executable lines (96.5%)**, with
42 uncovered lines accounted for exactly above. Public metadata accessors,
CRC and the byte parser are fully covered by this measurement. The ledger
does not count dependency code as coverage of this module.
