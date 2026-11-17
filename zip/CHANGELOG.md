# Changelog

## [Unreleased]

## [0.1.0] - 2026-11-17

### Added

- **ZIP archives on gaato's codecs**, ported from moonbitlang/core 25a579771
  (`archive/zip`, Apache-2.0; see NOTICE and docs/upstream.md): whole-archive
  reading and writing, bounded range readers for archives too large to hold,
  archive editing, and an incremental writer.
- **Methods**: Store, Deflate (levels 0–12 through gaato/deflate 0.4.0) and
  Zstandard (gaato/zstd 0.5.1) for reading and writing. Deflate64 (method 9)
  is read-only, with its 64 KiB window; writing it raises `InvalidArgument`.
  Other methods raise `UnsupportedCompression` with the method number.
- **Stricter reading than core**: archives with a prefix (self-extracting
  executables) are read with the offset corrected, central-directory entries
  that overlap each other's data are rejected, and a codec failure keeps its
  category as `Codec(ErrorKind)`. The end-of-central-directory record is
  chosen by one tiered rule shared by both readers: candidates that reach the
  end of the file are validated, more than one valid candidate is `Corrupt`,
  and trailing data is tolerated only when no candidate reaches the end.
  Limits apply after the record is chosen, and a ZIP64 directory that fails to
  parse falls back to the classic one only when that one is valid too.
- **Checked against other implementations**: Python zipfile, Info-ZIP unzip
  and 7-Zip read what this module writes, and this module reads their output,
  including three hash-pinned 7-Zip Deflate64 fixtures.
