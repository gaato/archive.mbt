// Derived from moonbitlang/core archive/zip/directory_reader.mbt at 25a579771; modified.
// Copyright 2026 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// Tail lookup includes the largest classic EOCD and its 16-bit comment.
const DIRECTORY_TAIL_SIZE : Int32 = 65557

///|
const DIRECTORY_CHUNK_SIZE : Int32 = 65536

///|
priv struct ClassicDirectoryEnd {
  offset : UInt64
  disk : UInt32
  central_disk : UInt32
  disk_entries : Int32
  entries : Int32
  central_size : UInt32
  central_offset : UInt32
  comment : BytesView
  probe_zip64 : Bool
}

///|
priv struct DirectoryBounds {
  offset : UInt64
  size : UInt64
  entries : UInt64
  comment : Bytes
}

///|
priv enum DirectoryPhase {
  Initial
  Tail(ReadRange)
  Locator(ClassicDirectoryEnd)
  Zip64(ClassicDirectoryEnd, UInt64)
  Zip64Probe(ClassicDirectoryEnd)
  DirectoryProbe(DirectoryReading)
  Records(DirectoryBounds, UInt64)
  Complete(Directory)
  Failed(ZipErrorKind, String)
}

///|
/// Metadata-only ZIP reader driven by caller-supplied byte ranges. Supports
/// classic ZIP and ZIP64 beyond 2 GiB without retaining the archive or inflating
/// payloads. Retains owned metadata plus a bounded incomplete directory record.
/// File reads, HTTP requests, source consistency, and cancellation between
/// calls belong to the caller. No I/O callback is retained or invoked.
struct DirectoryReader {
  archive_size : UInt64
  limits : DirectoryLimits
  mut phase : DirectoryPhase
  mut entries : Array[DirectoryEntry]
  mut pending : Bytes
  mut offset_gap : UInt64
  mut zip64_declared : UInt64
  mut selected_end : ClassicDirectoryEnd?
  mut selected_zip64 : UInt64?
  mut selected_size : UInt64
  mut selection : EndSelection?
}

///|
/// Start reading an archive of the supplied total byte size. No bytes are read
/// until the caller drives `advance` and fulfills the returned ranges.
pub fn DirectoryReader::DirectoryReader(
  archive_size : UInt64,
  limits~ : DirectoryLimits = DirectoryLimits(),
) -> DirectoryReader {
  {
    archive_size,
    limits,
    phase: Initial,
    entries: [],
    pending: b"",
    offset_gap: 0UL,
    zip64_declared: 0UL,
    selected_end: None,
    selected_zip64: None,
    selected_size: 0UL,
    selection: None,
  }
}

///|
/// Initially supply empty input; thereafter supply exactly the bytes requested
/// by the preceding `NeedRead`. Accumulate transport short reads before calling.
/// All ranges must refer to the same immutable archive. Input is borrowed only
/// for this call; retained metadata and incomplete records are copied.
/// Requests are at most 65,557 bytes, and directory chunks at most 64 KiB.
/// `Done` validates directory structure and referenced bounds, not local headers
/// or payload integrity. Empty calls after completion return the same listing.
/// Any error is latched and rethrown on subsequent calls.
pub fn DirectoryReader::advance(
  self : DirectoryReader,
  input : BytesView,
) -> DirectoryStep raise ZipError {
  if self.phase is Failed(kind, message) {
    raise ZipError(kind, message)
  }
  self.advance_selection(input) catch {
    ZipError(kind, message) => {
      self.phase = Failed(kind, message)
      self.entries = []
      self.pending = b""
      self.selected_end = None
      self.selection = None
      raise ZipError(kind, message)
    }
  }
}

///|
fn DirectoryReader::advance_selection(
  self : DirectoryReader,
  input : BytesView,
) -> DirectoryStep raise ZipError {
  self.advance_with_classic_fallback(input) catch {
    ZipError(kind, message) => {
      if kind.directory_failure() && self.selection is Some(selection) {
        return self.reject_candidate(selection, ZipError(kind, message))
      }
      raise ZipError(kind, message)
    }
  }
}

///|
fn DirectoryReader::advance_with_classic_fallback(
  self : DirectoryReader,
  input : BytesView,
) -> DirectoryStep raise ZipError {
  self.advance_active(input) catch {
    ZipError(kind, _) as error =>
      if kind.directory_failure() && self.selected_zip64 is Some(_) {
        self.begin_classic_records(self.selected_end.unwrap())
      } else {
        raise error
      }
  }
}

///|
fn expect_range_input(input : BytesView, length : Int32) -> Unit raise ZipError {
  guard input.length() == length else {
    raise ZipError(
      InvalidRead(expected=length, actual=input.length()),
      "zip: response length differs from requested range",
    )
  }
}

///|
fn range_read_length(remaining : UInt64, maximum : Int32) -> Int32 {
  if remaining < maximum.to_uint64() {
    remaining.to_int()
  } else {
    maximum
  }
}

///|
fn check_directory_limit(
  kind : LimitKind,
  limit : UInt64,
  actual : UInt64,
) -> Unit raise ZipError {
  guard actual <= limit else {
    raise ZipError(
      LimitExceeded(kind~, limit~, observed=actual),
      "zip: directory limit exceeded",
    )
  }
}

///|
fn DirectoryReader::advance_active(
  self : DirectoryReader,
  input : BytesView,
) -> DirectoryStep raise ZipError {
  match self.phase {
    Initial => {
      expect_range_input(input, 0)
      guard self.archive_size >= 22UL else {
        raise ZipError(
          MissingEndOfCentral,
          "zip: end of central directory not found",
        )
      }
      let length = range_read_length(self.archive_size, DIRECTORY_TAIL_SIZE)
      let range = { offset: self.archive_size - length.to_uint64(), length, }
      self.phase = Tail(range)
      NeedRead(range)
    }
    Tail(range) => {
      expect_range_input(input, range.length)
      self.begin_selection(copy_zip_input(input), range.offset)
    }
    DirectoryProbe(reading) => {
      expect_range_input(input, 4)
      guard input is [u32le(CENTRAL_HEADER_SIG)] else {
        raise ZipError(
          InvalidSignature,
          "zip: invalid central header signature",
        )
      }
      self.after_directory_probe(reading)
    }
    Locator(classic) => {
      expect_range_input(input, 20)
      if !(input is [u32le(ZIP64_LOCATOR_SIG), ..]) &&
        classic.central_size != MAX_U32 &&
        classic.central_offset != MAX_U32 {
        return self.begin_classic_records(classic)
      }
      guard input
        is [u32le(ZIP64_LOCATOR_SIG), u32le(disk), u64le(offset), u32le(disks)] else {
        return self.begin_classic_records(classic)
      }
      guard disk == 0 && disks == 1 else {
        return self.begin_classic_records(classic)
      }
      let locator = classic.offset - 20UL
      self.zip64_declared = offset
      guard offset <= locator && 56UL <= locator - offset else {
        return self.probe_zip64(classic)
      }
      self.phase = Zip64(classic, offset)
      NeedRead({ offset, length: 56, })
    }
    Zip64Probe(classic) => {
      expect_range_input(input, 56)
      let offset = classic.offset - 76UL
      let (entries, size, central) = checked_zip64_end(
        input,
        offset,
        classic.offset - 20UL,
        self.zip64_declared,
      ) catch {
        _ => return self.begin_classic_records(classic)
      }
      self.begin_zip64_records(
        classic,
        offset,
        entries,
        size,
        central,
        fallback=true,
      )
    }
    Zip64(classic, offset) => {
      expect_range_input(input, 56)
      let (entries, size, central) = checked_zip64_end(
        input,
        offset,
        classic.offset - 20UL,
        self.zip64_declared,
      ) catch {
        _ => return self.probe_zip64(classic)
      }
      self.begin_zip64_records(classic, offset, entries, size, central)
    }
    Records(bounds, offset) => {
      let end = bounds.offset + bounds.size
      let length = range_read_length(end - offset, DIRECTORY_CHUNK_SIZE)
      expect_range_input(input, length)
      let bytes : BytesView = if self.pending.length() == 0 {
        input
      } else {
        self.pending + input.to_owned()
      }
      let mut position = 0
      // Variable-length sizes sit at offset 28 of each 46-byte fixed header.
      while self.entries.length().to_uint64() < bounds.entries &&
            bytes.length() - position >= 46 &&
            bytes[position + 28:]
            is [u16le(name_size), u16le(extra_size), u16le(comment_size), ..] {
        let record_size = 46 +
          (name_size + extra_size + comment_size).reinterpret_as_int()
        guard record_size <= bytes.length() - position else { break }
        let parsed = parse_directory_record(
          Cursor(bytes[position:position + record_size], 0),
        )
        let raw = parsed.entry
        guard raw.local_offset <= bounds.offset - self.offset_gap else {
          raise ZipError(Truncated, "zip: local offset out of bounds")
        }
        let entry = { ..raw, local_offset: raw.local_offset + self.offset_gap, }
        // Local variable-length headers are deferred; their fixed prefix and
        // declared payload must at least fit before the central directory.
        guard entry.local_offset <= bounds.offset &&
          30UL <= bounds.offset - entry.local_offset &&
          entry.compressed_size <= bounds.offset - entry.local_offset - 30UL else {
          raise ZipError(
            Truncated,
            "zip: local record or payload out of bounds",
          )
        }
        self.entries.push(entry)
        position += record_size
      }
      let next = offset + length.to_uint64()
      let entries_done = self.entries.length().to_uint64() == bounds.entries
      if entries_done {
        validate_directory_signature(
          bytes[position:],
          end - next + (bytes.length() - position).to_uint64(),
        )
      }
      if next == end {
        guard entries_done else {
          raise ZipError(
            UnsupportedFeature,
            "zip: central directory size/count mismatch",
          )
        }
        self.complete(bounds.comment, bounds.offset)
      } else {
        self.pending = copy_zip_input(bytes[position:])
        self.phase = Records(bounds, next)
        NeedRead({
          offset: next,
          length: range_read_length(end - next, DIRECTORY_CHUNK_SIZE),
        })
      }
    }
    Complete(directory) => {
      expect_range_input(input, 0)
      Done(directory)
    }
    Failed(kind, message) => raise ZipError(kind, message)
  }
}

///|
fn DirectoryReader::begin_classic_records(
  self : DirectoryReader,
  classic : ClassicDirectoryEnd,
) -> DirectoryStep raise ZipError {
  self.selected_zip64 = None
  self.entries = []
  self.pending = b""
  guard classic.disk_entries == classic.entries else {
    raise ZipError(
      UnsupportedFeature,
      "zip: multi-disk archives are not supported",
    )
  }
  self.begin_records(
    classic.central_offset.to_uint64(),
    classic.central_size.to_uint64(),
    classic.entries.to_uint64(),
    classic.offset,
  )
}

///|
/// Try the physical SFX position only after the locator's own target failed.
fn DirectoryReader::probe_zip64(
  self : DirectoryReader,
  classic : ClassicDirectoryEnd,
) -> DirectoryStep raise ZipError {
  guard classic.offset >= 76UL && self.zip64_declared != classic.offset - 76UL else {
    return self.begin_classic_records(classic)
  }
  self.phase = Zip64Probe(classic)
  NeedRead({ offset: classic.offset - 76UL, length: 56, })
}

///|
fn DirectoryReader::begin_zip64_records(
  self : DirectoryReader,
  classic : ClassicDirectoryEnd,
  offset : UInt64,
  entries : UInt64,
  central_size : UInt64,
  central_offset : UInt64,
  fallback~ : Bool = false,
) -> DirectoryStep raise ZipError {
  check_zip64_classic(
    classic.disk_entries,
    classic.entries,
    classic.central_size,
    classic.central_offset,
    entries,
    central_size,
    central_offset,
  ) catch {
    _ => {
      if fallback {
        return self.begin_classic_records(classic)
      }
      return self.probe_zip64(classic)
    }
  }
  self.selected_zip64 = Some(offset)
  self.begin_records(central_offset, central_size, entries, offset)
}

///|
/// The central directory may end with one digital-signature record. Validate
/// its framing only, not the signature itself. `remaining` includes bytes in
/// this chunk and later chunks; the 16-bit size bounds retained input even when
/// the header straddles reads or an untrusted directory declares a huge tail.
fn validate_directory_signature(
  bytes : BytesView,
  remaining : UInt64,
) -> Unit raise ZipError {
  guard remaining != 0UL else { return }
  guard remaining >= 6UL && remaining <= 65541UL else {
    raise ZipError(UnsupportedFeature, "zip: invalid directory signature size")
  }
  if bytes is [u32le(signature), ..] {
    guard signature == DIRECTORY_SIGNATURE_SIG else {
      raise ZipError(InvalidSignature, "zip: invalid directory signature")
    }
  }
  if bytes is [u32le(_), u16le(size), ..] {
    guard 6UL + size.to_uint64() == remaining else {
      raise ZipError(
        UnsupportedFeature,
        "zip: directory signature size mismatch",
      )
    }
  }
}

///|
fn DirectoryReader::begin_records(
  self : DirectoryReader,
  offset : UInt64,
  size : UInt64,
  entries : UInt64,
  boundary : UInt64,
) -> DirectoryStep raise ZipError {
  guard offset <= boundary && size <= boundary - offset else {
    raise ZipError(Truncated, "zip: central directory out of bounds")
  }
  let reading = {
    classic: self.selected_end.unwrap(),
    zip64: self.selected_zip64,
    offset,
    size,
    entries,
    boundary,
  }
  // Every new reading, including a post-selection classic retry, must satisfy
  // the tier's structural probe before full parsing or limits can accept it.
  if entries == 0UL && size == 0UL {
    guard offset == boundary else {
      raise ZipError(
        UnsupportedFeature,
        "zip: empty directory has a prefix gap",
      )
    }
    return self.after_directory_probe(reading)
  }
  guard size >= 4UL else {
    raise ZipError(
      Truncated,
      "zip: central directory cannot hold its signature",
    )
  }
  self.phase = DirectoryProbe(reading)
  NeedRead({ offset: boundary - size, length: 4, })
}

///|
/// Parse only a reading that passed the shared signature/empty-gap probe.
fn DirectoryReader::begin_validated_records(
  self : DirectoryReader,
  reading : DirectoryReading,
) -> DirectoryStep raise ZipError {
  let { offset, size, entries, boundary, .. } = reading
  self.offset_gap = boundary - size - offset
  let offset = boundary - size
  self.selected_size = size
  guard entries <= 0x7fff_ffffUL else {
    raise ZipError(
      UnsupportedFeature,
      "zip: directory count exceeds in-memory capacity",
    )
  }
  guard entries <= size / 46UL else {
    raise ZipError(
      Truncated,
      "zip: central directory entry count exceeds its size",
    )
  }
  let comment = copy_zip_input(reading.classic.comment)
  guard size != 0UL else { return self.complete(comment, offset) }
  let bounds = { offset, size, entries, comment, }
  self.phase = Records(bounds, offset)
  NeedRead({ offset, length: range_read_length(size, DIRECTORY_CHUNK_SIZE), })
}

///|
fn DirectoryReader::complete(
  self : DirectoryReader,
  comment : Bytes,
  central_offset : UInt64,
) -> DirectoryStep raise ZipError {
  let order = Array::makei(self.entries.length(), i => i)
  order.sort_by((a, b) => {
    self.entries[a].local_offset.compare(self.entries[b].local_offset)
  })
  let record_ends = Array::make(self.entries.length(), central_offset)
  for i, index in order {
    let entry = self.entries[index]
    let end = if i + 1 < order.length() {
      self.entries[order[i + 1]].local_offset
    } else {
      central_offset
    }
    guard entry.local_offset <= end &&
      30UL <= end - entry.local_offset &&
      entry.compressed_size <= end - entry.local_offset - 30UL else {
      raise ZipError(
        UnsupportedFeature,
        "zip: shared or overlapping local records",
      )
    }
    record_ends[index] = end
  }
  // Limits do not decide between ZIP64 and classic. Only a directory that
  // passed framing, counts and extents is the chosen reading.
  check_directory_limit(
    DirectoryBytes,
    self.limits.max_directory_bytes,
    self.selected_size,
  )
  check_directory_limit(
    Entries,
    self.limits.max_entries,
    self.entries.length().to_uint64(),
  )
  let directory = {
    entries: self.entries,
    comment,
    central_offset,
    record_ends,
  }
  self.entries = []
  self.pending = b""
  self.selected_end = self.selected_end.map(end => { ..end, comment: b""[:], })
  self.phase = Complete(directory)
  Done(directory)
}
