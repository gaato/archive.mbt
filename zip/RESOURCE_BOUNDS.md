# Resource bounds

All payload and container code is pure MoonBit and does no I/O. This module
does not implement the byte-stream codec contract itself: ZIP is a layer
above `gaato/codec_bytes`, retaining its own container limits and CRC checks.
Defaults are compatibility defaults, not a suggested untrusted-input budget.

## Enforced limits

| Structure | Bound and failure | Tests |
| --- | --- | --- |
| Whole source and retained record views | `ReadLimits.max_package_bytes`, checked before owning the source. One source copy is retained; the caller's original may coexist. Record views share the retained source. Negative limits raise `InvalidArgument`. | `src/zip_test.mbt`, "zip package-size limit"; `src/zip_bytes_wbtest.mbt` |
| Whole archive entries | `max_entries`, also Int32 capacity. Metadata and local extent arrays are O(entries). Sorting uses O(entries) index/range storage; no pairwise overlap table. | `src/zip_test.mbt`, sentinel-boundary and limits tests; `src/methods_wbtest.mbt`, "shared and overlapping local records are refused before decoding" |
| Decoded payloads | `max_entry_uncompressed_bytes` and `max_total_uncompressed_bytes`; declarations are checked before decoding, actual bytes while decoding. The trial buffer starts at min(declared, 4 KiB), doubles only after filling, and never grows past the declaration. Decoding writes directly into views of that buffer; a one-byte scratch view can drain the end marker or detect a lying size. A lying declaration falls back to an 8 KiB counting buffer before exact allocation; the trial buffer may temporarily coexist with the fallback. | `src/declared_size_test.mbt`; `src/zip_coverage_wbtest.mbt`, declared-size and cancellation tests; `src/reuse_wbtest.mbt`, "direct decode views handle growth, exact output and understated declarations" |
| Chosen directory | `DirectoryLimits.max_directory_bytes` and `max_entries`, checked after structural validation chooses ZIP64 or classic. These do not bound speculative metadata I/O or temporary selection storage. The intrinsic array capacity is Int32. | `src/range_test.mbt`, directory limits and synthetic ZIP64 source tests; `src/review3_wbtest.mbt`, false-record and decoy-limit regressions |
| Range responses | Tail at most 65,557 bytes; directory and compressed chunks at most 65,536; local name and extra responses at most 65,535 each. One owned compressed chunk is retained. Local headers/descriptors cannot cross the next local record. | `src/range_test.mbt`; `src/methods_wbtest.mbt`, SFX and overlap tests |
| Incomplete directory record | Less than 46 + 3 * 65,535 = 196,651 bytes, plus a 64 KiB response while joining chunks. A directory signature retains at most 65,541 bytes. | `src/range_test.mbt`, metadata buffer ownership and split directory tests; `src/zip_coverage_wbtest.mbt`, directory-signature checks |
| Directory metadata | Owned names (at most 65,535 encoded bytes each), fixed-size entry metadata and one UInt64 endpoint per entry, O(entries). The comment is at most 65,535 bytes. | `src/range_test.mbt`; `src/methods_wbtest.mbt`, maximum-comment SFX test |
| Selection work | One owned tail of at most 65,557 bytes plus O(candidates in that tail) metadata. Tier 1 probes every EOF-reaching candidate until ambiguity is established; tier 2 probes in reverse order until success. Each candidate may request a locator, up to two 56-byte ZIP64 records and up to two 4-byte directory signatures, without parsing its entries. After selection, at most one ZIP64 directory parse and one classic parse; the classic retry first passes the same probe (at most one additional 4-byte read), and failed ZIP64 metadata is discarded. Temporary names, entries and extents are O(the attempted directory), structurally bounded by archive extents and Int32 capacity, not caller limits. The eager reader drives the same engine and polls cancellation between ranges. | `src/eocd_selection_wbtest.mbt`, survey matrix, ambiguity, tier priority, errors and the post-selection classic-signature regression; prior review regressions |
| Streaming decoded output | `EntryReadLimits.max_output_bytes`, checked against declarations on open and actual bytes each step, with UInt64 overflow checks. Output writes only within the caller's slice; failed steps report zero produced. | `src/range_test.mbt`; `src/methods_wbtest.mbt`, one-byte output and latched codec-error tests |
| Whole writer final output | `max_output_bytes` and Int32 capacity, counted before allocating the final archive. Prepared compressed payloads and the archive model are additional memory. | `src/zip_test.mbt`, write limits; `src/zip_coverage_wbtest.mbt`, output counting and boundary tests |
| Streaming writer sizes | UInt64 output position and entry length; declared size before input and at end. ZIP64 is reserved using the selected codec's compressed-size bound. Name/comment at most 65,535 bytes. Failed sink releases directory and codec storage. | `src/stream_writer_wbtest.mbt`, declared sizes, sink poisoning, overflow and reentrancy tests; `src/codecs_bounds_wbtest.mbt`, "known-size chunked headers reserve ZIP64 with each codec's size bound" |

## Codec storage

One decoder is held for the current streaming read. Chunked writers retain
one encoder per used method (at most one Deflate and one Zstandard), even
across intervening Store entries, and one shared 64 KiB scratch buffer.
Encoders are reset for each new entry of their method, and the caches and
scratch are released on finish or sink failure. Reuse, object identity and
unchanged payload bytes are checked in `src/reuse_wbtest.mbt`.
Each compressed emission additionally allocates an immutable chunk of at most
64 KiB before the sink runs. The sink may retain `view.to_owned()` safely;
memory retained by that collecting sink belongs to the caller. The full-size
boundary across entries is checked in `src/review2_wbtest.mbt`.
Deflate's
decoder workspace is fixed by the dependency (46,592 element-payload bytes).
Deflate64 uses a **65,536-byte history window**, with fixed Huffman tables,
builder scratch and unfinished-input storage: **79,384 element-payload bytes**
from `gaato/deflate/deflate64.decoder_memory_bound()` in 0.4.0, excluding runtime
object headers and caller buffers. The range reader holds one decoder per
active entry; a small output limit does not shrink its history. The 147,456-byte
7-Zip fixtures exercise matches at distance 49,152 on both APIs.
Zstandard's
decoder bounds the advertised window with its default maximum window bits
(27, at most 128 MiB), plus tables and frame/block storage. A small output
limit is not a codec memory limit. These bounds are owned by the dependencies;
see [Deflate bounds](https://github.com/gaato/codecs.mbt/blob/main/deflate/RESOURCE_BOUNDS.md)
and [Zstandard bounds](https://github.com/gaato/codecs.mbt/blob/main/zstd/RESOURCE_BOUNDS.md).
Whole reads use the trial buffer and one-byte probe described above, or 8 KiB
counting scratch. Encoders allocate according
to the level they receive; Deflate 0.4.0's levels 10–12 use up to 7,056,748
element-payload bytes for the encoder at its default window. Deflate64 has
no encoder here: write requests fail with `InvalidArgument` before output.
CRC uses one `gaato/crc.Digest` per active member.

## Left to the caller

The in-memory `Archive` retains every decoded payload, original source,
metadata and prepared output as described above; pick total and package
limits together. Growing arrays/buffers can have spare capacity, and model,
record views and returned bytes can coexist. Object overhead is runtime
dependent and not included in byte ceilings.

`Writer` has no metadata-count or total-output ceiling: it retains one encoded
central record per entry until `finish`. Bound entry count, names and supplied
data in the calling application. A sink must consume each borrowed view before
returning. Range readers require a consistent immutable archive. No limit
here validates extraction paths, filesystem permissions or symlinks.
