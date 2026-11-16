// Derived from moonbitlang/core archive/zip/reader.mbt at 25a579771; modified.
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
/// One codec per payload, stopped at its first member. ZIP checks the exact
/// compressed length independently, including trailing frames and bytes.
fn entry_decoder(compression : Compression) -> &@codec_bytes.Decode {
  match compression {
    Deflate => (@deflate.Decoder(until=EndOfMember) : &@codec_bytes.Decode)
    Zstandard => (@zstd.Decoder(until=EndOfMember) : &@codec_bytes.Decode)
    Store => abort("stored entries do not use a decoder")
  }
}

///|
fn entry_encoder(
  compression : Compression,
  level : Int32,
) -> &@codec_bytes.Encode {
  match compression {
    Deflate => (@deflate.Encoder(level~) : &@codec_bytes.Encode)
    Zstandard => (@zstd.Encoder(level~) : &@codec_bytes.Encode)
    Store => abort("stored entries do not use an encoder")
  }
}

///|
fn compress_entry(
  data : BytesView,
  compression : Compression,
  level : Int32,
) -> Bytes {
  match compression {
    Store => data.to_owned()
    Deflate => @deflate.compress(data, level~)
    Zstandard => @zstd.compress(data, level~)
  }
}

///|
/// Count with a fixed scratch buffer before allocating the result. In
/// particular, attacker-controlled decoded sizes never size an allocation.
fn decode_compressed_entry(
  compressed : BytesView,
  compression : Compression,
  max_output : Int32,
  limit_kind : LimitKind,
  reported_limit : Int32,
  cancelled : () -> Bool,
) -> Bytes raise ZipError {
  check_cancelled(cancelled)
  let decoder = entry_decoder(compression)
  let scratch = FixedArray::make(8192, b'\x00')
  let previous = (reported_limit - max_output).to_uint64()
  let size = for position = 0, total = 0UL {
    let status = decoder.step(
      compressed[position:],
      scratch.mut_view(),
      end=true,
    ) catch {
      err => raise wrap_codec_error(err)
    }
    let position = position + decoder.last_consumed()
    let total = total + decoder.last_produced().to_uint64()
    check_cancelled(cancelled)
    guard total <= max_output.to_uint64() else {
      raise ZipError(
        LimitExceeded(
          kind=limit_kind,
          limit=reported_limit.to_uint64(),
          observed=previous + total,
        ),
        "zip: decompressed size limit exceeded",
      )
    }
    match status {
      Done => {
        guard position == compressed.length() else {
          raise ZipError(
            Codec(@codec.ErrorKind::TrailingData),
            "zip: trailing bytes in compressed payload",
          )
        }
        break total.to_int()
      }
      NeedMoreInput =>
        raise ZipError(
          Codec(@codec.ErrorKind::Truncated),
          "zip: truncated compressed payload",
        )
      NeedMoreOutput => continue position, total
    }
  }
  decoder.reset()
  let output = FixedArray::make(size, b'\x00')
  for position = 0, produced = 0 {
    check_cancelled(cancelled)
    let status = decoder.step(
      compressed[position:],
      scratch.mut_view(end=4096),
      end=true,
    ) catch {
      err => raise wrap_codec_error(err)
    }
    let position = position + decoder.last_consumed()
    let count = decoder.last_produced()
    guard count <= size - produced else {
      raise ZipError(SizeMismatch, "zip: counted decoded size changed")
    }
    output.blit_from_bytesview(
      produced,
      borrowed_zip_buffer_bytes(scratch)[:count],
    )
    let produced = produced + count
    if status is Done {
      guard produced == size && position == compressed.length() else {
        raise ZipError(SizeMismatch, "zip: counted decoded size changed")
      }
      break
    }
    continue position, produced
  }
  owned_zip_buffer_to_bytes(output)
}

///|
/// Grow only with decoded bytes, then fall back to counting when a declaration
/// lies. An honest payload needs one pass without trusting its size to allocate.
fn inflate_declared_entry(
  compressed : BytesView,
  declared : Int32,
  max_output : Int32,
  limit_kind : LimitKind,
  reported_limit : Int32,
  cancelled : () -> Bool,
  compression~ : Compression = Deflate,
) -> Bytes raise ZipError {
  if declared <= max_output {
    let decoder = entry_decoder(compression)
    // Grow with actual output, never with an untrusted declaration. Decode
    // directly into the owned buffer's views instead of copying every chunk.
    let mut output = FixedArray::make(declared.min(4096), b'\x00')
    let mut produced = 0
    let mut probe : FixedArray[Byte] = []
    check_cancelled(cancelled)
    let result : Bytes? = for position = 0 {
      if produced == output.length() && produced < declared {
        let capacity = produced + (declared - produced).min(produced.max(4096))
        let larger = FixedArray::make(capacity, b'\x00')
        larger.blit_from_bytesview(
          0,
          borrowed_zip_buffer_bytes(output)[:produced],
        )
        output = larger
      }
      // A full declared output may still need to consume its end marker.
      // A separate one-byte view detects an understated size without growing
      // the result past the declaration, including at the Int32 boundary.
      let full = produced == declared
      let target = if full {
        if probe.is_empty() {
          probe = FixedArray::make(1, b'\x00')
        }
        probe.mut_view()
      } else {
        output.mut_view(
          start=produced,
          end=produced + (output.length() - produced).min(4096),
        )
      }
      let status = decoder.step(compressed[position:], target, end=true) catch {
        _ => break None
      }
      check_cancelled(cancelled)
      let count = decoder.last_produced()
      guard count <= declared - produced else { break None }
      produced += count
      let position = position + decoder.last_consumed()
      match status {
        Done =>
          break if position == compressed.length() && produced == declared {
            Some(owned_zip_buffer_to_bytes(output))
          } else {
            None
          }
        NeedMoreInput => break None
        NeedMoreOutput => continue position
      }
    }
    if result is Some(data) {
      return data
    }
  }
  inflate_entry(
    compressed,
    max_output,
    limit_kind,
    reported_limit,
    cancelled,
    compression~,
  )
}
