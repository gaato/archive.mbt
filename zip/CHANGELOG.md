# Changelog

## [Unreleased]

### Added

- Initial `gaato/zip` module, ported from moonbitlang/core 25a579771.
- Store, Deflate and Zstandard reading and writing through gaato codecs.
- SFX offset correction, overlap rejection and structured codec errors.
- Bounded range readers, archive editing and incremental writer from core.

### Fixed

- Keep complete classic directories out of ZIP64 probing when a long comment
  hides a locator-like filename, and prefer valid ZIP64 locator targets over
  signatures inside extensible sectors while retaining the SFX fallback.
- Reuse chunked encoders and shared output scratch across entries, and decode
  directly into growing output views without per-chunk byte copies.
- Give collecting sinks immutable compressed chunks, including full 64 KiB
  output buffers, while retaining encoder and scratch reuse.
- Ignore invalid optional ZIP64 locators in prefixed filenames and accept
  framed central-directory digital signatures with both reader APIs.
- Share a tiered selector between both APIs: validate EOF-reaching candidates,
  reject multiple valid records with `Corrupt`, and tolerate trailing data only
  when no candidate reaches EOF. Keep ZIP64/classic retry and post-selection
  limits. Add the ten-reader survey matrix and generated Python differential data.
- Require the same structural signature/empty-gap probe for a classic retry
  after the selected ZIP64 directory fails full parsing.

## [0.1.0]

Initial version; release pending.
