// Derived from moonbitlang/core archive/zip/stream_writer.mbt at 25a579771; modified.
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
priv enum WriterMode {
  Ready
  Writing(PendingEntry)
  Emitting
  Finished
  Failed
}

///|
priv struct PendingEntry {
  name : Bytes
  compression : Compression
  offset : UInt64
  expected_size : UInt64?
  zip64 : Bool
  crc : @crc.Digest
  mut size : UInt64
  mut compressed_size : UInt64
}

///|
/// An incremental ZIP writer over a synchronous byte sink. `add` handles an
/// already loaded file; `begin_entry`/`write`/`end_entry` handle bounded chunks.
/// Retains central-directory records, current-entry metadata and codec buffers.
/// The sink must consume each view before returning. A sink exception poisons
/// the writer and is propagated unchanged; no further output can be emitted.
struct Writer {
  sink : (BytesView) -> Unit raise
  level : Int32
  mut mode : WriterMode
  mut offset : UInt64
  mut directory : Array[Bytes]
  mut has_zip64 : Bool
  mut deflater : &@codec_bytes.Encode?
  mut deflate_encoder : &@codec_bytes.Encode?
  mut zstd_encoder : &@codec_bytes.Encode?
  mut scratch : FixedArray[Byte]
}

///|
/// Create a ZIP writer. The sink supplies file/socket I/O or collects chunks;
/// this package itself performs no I/O. Calling `finish` writes the directory.
/// `level` is passed unchanged to the selected codec; 6 is the default.
/// Writer methods raise `ZipError` for their own failures and propagate sink
/// errors unchanged.
pub fn Writer::Writer(
  sink : (BytesView) -> Unit raise,
  level~ : Int32 = 6,
) -> Writer {
  {
    sink,
    level,
    mode: Ready,
    offset: 0UL,
    directory: [],
    has_zip64: false,
    deflater: None,
    deflate_encoder: None,
    zstd_encoder: None,
    scratch: [],
  }
}

///|
/// Number of successfully emitted bytes, including headers and descriptors.
pub fn Writer::position(self : Writer) -> UInt64 {
  self.offset
}

///|
/// Whether the directory and archive trailer have been successfully emitted.
pub fn Writer::is_finished(self : Writer) -> Bool {
  self.mode is Finished
}

///|
/// Whether an emission failure has made this writer unusable.
pub fn Writer::is_failed(self : Writer) -> Bool {
  self.mode is Failed
}

///|
fn Writer::require_ready(self : Writer) -> Unit raise ZipError {
  match self.mode {
    Ready => ()
    Emitting => raise ZipError(InvalidState, "zip: reentrant sink write")
    _ => raise ZipError(InvalidState, "zip: writer is not ready for an entry")
  }
}

///|
fn Writer::pending(self : Writer) -> PendingEntry raise ZipError {
  guard self.mode is Writing(entry) else {
    raise ZipError(InvalidState, "zip: no open entry")
  }
  entry
}

///|
fn Writer::emit(self : Writer, bytes : BytesView) -> Unit raise {
  guard bytes.length() > 0 else { return }
  let size = bytes.length().to_uint64()
  guard size <= 0xffff_ffff_ffff_ffffUL - self.offset else {
    self.mode = Failed
    self.release_storage()
    raise ZipError(UnsupportedFeature, "zip: output exceeds UInt64 range")
  }
  let mode = self.mode
  // Reentrant writes from a sink and retries after partial I/O must fail.
  self.mode = Emitting
  errdefer {
    self.mode = Failed
    self.release_storage()
  }
  (self.sink)(bytes)
  self.offset += size
  self.mode = mode
}

///|
fn Writer::release_storage(self : Writer) -> Unit {
  self.directory = []
  self.deflater = None
  self.deflate_encoder = None
  self.zstd_encoder = None
  self.scratch = []
}

///|
fn stream_name(name : String) -> Bytes raise ZipError {
  let bytes = @encoding/utf8.encode(name)
  guard bytes.length() <= 0xffff else {
    raise ZipError(UnsupportedFeature, "zip: entry name too long")
  }
  bytes
}

///|
fn stream_local_header(
  name : Bytes,
  compression : Compression,
  crc : UInt32,
  size : UInt64,
  compressed_size : UInt64,
  zip64 : Bool,
  descriptor : Bool,
) -> Bytes {
  let out = @buffer.Buffer(
    size_hint=30 + name.length() + (if zip64 { 20 } else { 0 }),
  )
  out.write_uint_le(LOCAL_HEADER_SIG)
  out.write_uint16_le(
    if compression is Zstandard {
      (63).to_uint16()
    } else if zip64 {
      (45).to_uint16()
    } else {
      (20).to_uint16()
    },
  )
  out.write_uint16_le(
    (FLAG_UTF8 | (if descriptor { FLAG_DATA_DESCRIPTOR } else { 0 })).to_uint16(),
  )
  out.write_uint16_le(compression.code().to_uint16())
  out.write_uint_le(0U)
  out.write_uint_le(crc)
  out.write_uint_le(if zip64 { MAX_U32 } else { compressed_size.to_uint() })
  out.write_uint_le(if zip64 { MAX_U32 } else { size.to_uint() })
  out.write_uint16_le(name.length().to_uint16())
  out.write_uint16_le(if zip64 { (20).to_uint16() } else { (0).to_uint16() })
  out.write_bytes(name)
  if zip64 {
    out.write_uint16_le(ZIP64_EXTRA_ID.to_uint16())
    out.write_uint16_le((16).to_uint16())
    out.write_uint64_le(size)
    out.write_uint64_le(compressed_size)
  }
  out.to_bytes()
}

///|
fn stream_central_record(
  name : Bytes,
  compression : Compression,
  crc : UInt32,
  size : UInt64,
  compressed_size : UInt64,
  offset : UInt64,
  zip64 : Bool,
  descriptor : Bool,
) -> Bytes {
  let large_offset = offset >= 0xffff_ffffUL
  let extra_payload = (if zip64 { 16 } else { 0 }) +
    (if large_offset { 8 } else { 0 })
  let extra_size = if extra_payload == 0 { 0 } else { 4 + extra_payload }
  let out = @buffer.Buffer(size_hint=46 + name.length() + extra_size)
  let version = if compression is Zstandard {
    (63).to_uint16()
  } else if zip64 || large_offset {
    (45).to_uint16()
  } else {
    (20).to_uint16()
  }
  out.write_uint_le(CENTRAL_HEADER_SIG)
  out.write_uint16_le(version)
  out.write_uint16_le(version)
  out.write_uint16_le(
    (FLAG_UTF8 | (if descriptor { FLAG_DATA_DESCRIPTOR } else { 0 })).to_uint16(),
  )
  out.write_uint16_le(compression.code().to_uint16())
  out.write_uint_le(0U)
  out.write_uint_le(crc)
  out.write_uint_le(if zip64 { MAX_U32 } else { compressed_size.to_uint() })
  out.write_uint_le(if zip64 { MAX_U32 } else { size.to_uint() })
  out.write_uint16_le(name.length().to_uint16())
  out.write_uint16_le(extra_size.to_uint16())
  out.write_uint16_le((0).to_uint16())
  out.write_uint16_le((0).to_uint16())
  out.write_uint16_le((0).to_uint16())
  out.write_uint_le(0U)
  out.write_uint_le(if large_offset { MAX_U32 } else { offset.to_uint() })
  out.write_bytes(name)
  if extra_payload > 0 {
    out.write_uint16_le(ZIP64_EXTRA_ID.to_uint16())
    out.write_uint16_le(extra_payload.to_uint16())
    if zip64 {
      out.write_uint64_le(size)
      out.write_uint64_le(compressed_size)
    }
    if large_offset {
      out.write_uint64_le(offset)
    }
  }
  out.to_bytes()
}

///|
/// Compress and emit one complete file immediately using the whole-buffer
/// codec helper. Chunked encoder caches are used by begin_entry instead.
/// Stored files are sent directly to the sink without an intermediate copy.
pub fn Writer::add(
  self : Writer,
  name : String,
  data : BytesView,
  compression~ : Compression = Deflate,
) -> Unit raise {
  self.require_ready()
  let name = stream_name(name)
  let crc = @crc.crc32_update(0U, data)
  let compressed : BytesView = match compression {
    Store => data
    Deflate | Zstandard => compress_entry(data, compression, self.level)
  }
  let size = data.length().to_uint64()
  let compressed_size = compressed.length().to_uint64()
  let offset = self.offset
  self.emit(
    stream_local_header(
      name, compression, crc, size, compressed_size, false, false,
    ),
  )
  self.emit(compressed)
  self.directory.push(
    stream_central_record(
      name, compression, crc, size, compressed_size, offset, false, false,
    ),
  )
}

///|
/// Open a chunked entry. Supply the known uncompressed size to use classic
/// headers when it fits safely; unknown sizes reserve ZIP64 fields up front.
/// The declared size is checked before accepting input and before closing.
pub fn Writer::begin_entry(
  self : Writer,
  name : String,
  compression~ : Compression = Deflate,
  size? : UInt64,
) -> Unit raise {
  self.require_ready()
  let name = stream_name(name)
  // Reserve ZIP64 using the selected codec's bound, before a header is sent.
  // Core's DEFLATE heuristic does not bound these encoders' worst-case output.
  let zip64 = size
    .map(n => {
      if n >= 0xffff_ffffUL {
        return true
      }
      // Below the sentinel this narrowing and both bounds fit Int64.
      let bound = match compression {
        Store => n.reinterpret_as_int64()
        Deflate => @deflate.compress_bound(n.reinterpret_as_int64())
        Zstandard => @zstd.compress_bound(n.reinterpret_as_int64())
      }
      bound >= 0xffff_ffffL
    })
    .unwrap_or(true)
  if !(compression is Store) {
    let cached = if compression is Deflate {
      self.deflate_encoder
    } else {
      self.zstd_encoder
    }
    let encoder = match cached {
      Some(encoder) => {
        encoder.reset()
        encoder
      }
      None => {
        let encoder = entry_encoder(compression, self.level)
        if compression is Deflate {
          self.deflate_encoder = Some(encoder)
        } else {
          self.zstd_encoder = Some(encoder)
        }
        encoder
      }
    }
    self.deflater = Some(encoder)
    if self.scratch.is_empty() {
      self.scratch = FixedArray::make(65536, b'\x00')
    }
  } else {
    self.deflater = None
  }
  let entry = {
    name,
    compression,
    offset: self.offset,
    expected_size: size,
    zip64,
    crc: @crc.crc32.digest(),
    size: 0UL,
    compressed_size: 0UL,
  }
  self.mode = Writing(entry)
  self.emit(stream_local_header(name, compression, 0U, 0UL, 0UL, zip64, true))
  self.has_zip64 = self.has_zip64 || zip64
}

///|
fn Writer::pump(
  self : Writer,
  input : BytesView,
  action : @codec_bytes.EncodeAction,
) -> Unit raise {
  if self.deflater is Some(deflater) {
    let mut consumed = 0
    for ;; {
      let status = deflater.step(
        input[consumed:],
        self.scratch.mut_view(),
        action~,
      ) catch {
        err => raise wrap_codec_error(err)
      }
      consumed += deflater.last_consumed()
      let produced = deflater.last_produced()
      if produced > 0 {
        // A sink may retain view.to_owned(), which shares a whole backing
        // buffer. Never expose scratch that a later step or entry rewrites.
        self.emit(Bytes::from_array(self.scratch[:produced]))
      }
      guard status is NeedMoreOutput else { break }
    }
  }
}

///|
/// Consume a chunk of the current entry, updating CRC while its bytes are hot.
/// Produced compressed blocks are sent to the sink before this call returns.
pub fn Writer::write(self : Writer, bytes : BytesView) -> Unit raise {
  let entry = self.pending()
  let length = bytes.length().to_uint64()
  guard length <= 0xffff_ffff_ffff_ffffUL - entry.size else {
    raise ZipError(UnsupportedFeature, "zip: entry exceeds UInt64 range")
  }
  if entry.expected_size is Some(size) {
    guard length <= size - entry.size else {
      raise ZipError(SizeMismatch, "zip: input exceeds declared size")
    }
  }
  let start = self.offset
  entry.crc.write(bytes)
  match entry.compression {
    Store => self.emit(bytes)
    Deflate | Zstandard => self.pump(bytes, Continue)
  }
  entry.size += length
  entry.compressed_size += self.offset - start
}

///|
/// Finish the current entry and emit its data descriptor. The next file may
/// then be started. One encoder per used compression method and one shared
/// 64 KiB output buffer are retained, reset and reused until finish or failure.
pub fn Writer::end_entry(self : Writer) -> Unit raise {
  let entry = self.pending()
  if entry.expected_size is Some(size) {
    guard entry.size == size else {
      raise ZipError(SizeMismatch, "zip: input is shorter than declared size")
    }
  }
  let start = self.offset
  if !(entry.compression is Store) {
    self.pump(b"", Finish)
  }
  entry.compressed_size += self.offset - start
  let crc = entry.crc.value().to_uint()
  let descriptor = @buffer.Buffer(size_hint=if entry.zip64 { 24 } else { 16 })
  descriptor.write_uint_le(DATA_DESCRIPTOR_SIG)
  descriptor.write_uint_le(crc)
  if entry.zip64 {
    descriptor.write_uint64_le(entry.compressed_size)
    descriptor.write_uint64_le(entry.size)
  } else {
    descriptor.write_uint_le(entry.compressed_size.to_uint())
    descriptor.write_uint_le(entry.size.to_uint())
  }
  self.emit(descriptor.to_bytes())
  self.directory.push(
    stream_central_record(
      entry.name,
      entry.compression,
      crc,
      entry.size,
      entry.compressed_size,
      entry.offset,
      entry.zip64,
      true,
    ),
  )
  self.mode = Ready
}

///|
/// Write the central directory and close the ZIP. Further writes are rejected.
/// The optional archive comment must fit the ZIP 16-bit comment length.
pub fn Writer::finish(self : Writer, comment~ : BytesView = b"") -> Unit raise {
  self.require_ready()
  guard comment.length() <= 0xffff else {
    raise ZipError(UnsupportedFeature, "zip: archive comment too long")
  }
  let central_offset = self.offset
  for record in self.directory {
    self.emit(record)
  }
  let central_size = self.offset - central_offset
  let count = self.directory.length()
  let zip64 = self.has_zip64 ||
    count >= 0xffff ||
    central_size >= 0xffff_ffffUL ||
    central_offset >= 0xffff_ffffUL
  let out = @buffer.Buffer(size_hint=98 + comment.length())
  if zip64 {
    out.write_uint_le(ZIP64_EOCD_SIG)
    out.write_uint64_le(44UL)
    out.write_uint16_le((45).to_uint16())
    out.write_uint16_le((45).to_uint16())
    out.write_uint_le(0U)
    out.write_uint_le(0U)
    out.write_uint64_le(count.to_uint64())
    out.write_uint64_le(count.to_uint64())
    out.write_uint64_le(central_size)
    out.write_uint64_le(central_offset)
    out.write_uint_le(ZIP64_LOCATOR_SIG)
    out.write_uint_le(0U)
    out.write_uint64_le(self.offset)
    out.write_uint_le(1U)
  }
  out.write_uint_le(END_OF_CENTRAL_SIG)
  out.write_uint_le(0U)
  out.write_uint16_le(
    if zip64 {
      (0xffff).to_uint16()
    } else {
      count.to_uint16()
    },
  )
  out.write_uint16_le(
    if zip64 {
      (0xffff).to_uint16()
    } else {
      count.to_uint16()
    },
  )
  out.write_uint_le(if zip64 { MAX_U32 } else { central_size.to_uint() })
  out.write_uint_le(if zip64 { MAX_U32 } else { central_offset.to_uint() })
  out.write_uint16_le(comment.length().to_uint16())
  out.write_bytes(comment)
  self.emit(out.to_bytes())
  self.mode = Finished
  self.release_storage()
}
