///|
test "known-size chunked headers reserve ZIP64 with each codec's size bound" {
  for compression in [Store, Deflate, Zstandard] {
    for
      size in [
        0UL,
        0xffff_ffffUL - 2000000UL,
        0xffff_ffffUL,
        0xffff_ffff_ffff_ffffUL,
      ] {
      let sink = @buffer.Buffer()
      let writer = Writer(bytes => sink.write_bytes(bytes.to_owned()))
      writer.begin_entry("x", compression~, size~)
      let expected = size >= 0xffff_ffffUL ||
        (size > 0UL && !(compression is Store))
      assert_eq(writer.pending().zip64, expected)
      assert_eq(read_u32_le_at_raw(sink.to_bytes(), 18) == MAX_U32, expected)
    }
  }
}

///|
fn raw_compressed_zip(
  data : Bytes,
  raw : Bytes,
  compression : Compression,
) -> Bytes raise ZipError {
  let archive = Archive()
  archive.add("x", data, compression~)
  let entry = archive.entries[0]
  let out = Output::writing(None)
  out.write_local_record(
    entry,
    b"x",
    { compressed_size: raw.length(), compressed: Some(raw), },
    false,
    false,
  )
  let central = out.size
  out.write_central_record(entry, b"x", 0, raw.length(), false, false)
  out.write_generated_classic_end_record(
    false,
    1,
    out.size - central,
    central,
    b"",
  )
  out.finish()
}

///|
test "Zstandard: truncation, trailing frames, frame checksum and ZIP output bounds" {
  let data = b"hello Zstandard ZIP".repeat(1000)
  let raw = @zstd.compress(data)
  let corrupt_checksum = raw.to_fixedarray()
  corrupt_checksum[raw.length() - 1] = corrupt_checksum[raw.length() - 1] ^ 1
  for
    (payload, category) in [
      (raw[:raw.length() - 1].to_owned(), @codec.ErrorKind::Truncated),
      (raw + @zstd.compress(b"another frame"), @codec.ErrorKind::TrailingData),
      (Bytes::from_array(corrupt_checksum), @codec.ErrorKind::ChecksumMismatch),
    ] {
    let bytes = raw_compressed_zip(data, payload, Zstandard)
    expect_zip_kind(() => ignore(read_all(bytes)), Codec(category))
    let reader = listing(bytes).open_entry(0)
    let scratch = FixedArray::make(37, b'\x00')
    for input = b"" {
      let step = reader.step(input, scratch.mut_view()) catch {
        ZipError(kind, _) => {
          assert_eq(kind, Codec(category))
          break
        }
      }
      match step {
        Done => fail("malformed compressed member accepted")
        NeedMoreOutput => continue b""
        NeedRead(range) =>
          continue bytes[range.offset.to_int():range.offset.to_int() +
            range.length].to_owned()
      }
    }
  }
  let bytes = raw_compressed_zip(b"lie", raw, Zstandard)
  try
    read_all(bytes, limits=ReadLimits(max_entry_uncompressed_bytes=100))
  catch {
    ZipError(
      LimitExceeded(kind=EntryUncompressedBytes, limit=100UL, observed~),
      _,
    ) => assert_true(observed > 100UL)
    err => raise err
  } noraise {
    _ => fail("actual decoded output limit was not enforced")
  }
  let bytes = raw_compressed_zip(data, raw, Zstandard)
  expect_zip_kind(
    () => {
      ignore(
        listing(bytes).open_entry(
          0,
          limits=EntryReadLimits(max_output_bytes=0UL),
        ),
      )
    },
    LimitExceeded(
      kind=EntryUncompressedBytes,
      limit=0UL,
      observed=data.length().to_uint64(),
    ),
  )
}

///|
test "all methods cross 64 KiB compressed reads and retain directory metadata" {
  let mut state = 0x93245217U
  let data = Bytes::makei(140000, _ => {
    state = state * 1664525U + 1013904223U
    (state >> 24).to_byte()
  })
  let archive = Archive()
  archive.set_comment(b"comment")
  for compression in [Store, Deflate, Zstandard] {
    archive.add("\{compression.code()}/", data, compression~)
  }
  let bytes = write(archive)
  let directory = listing(bytes)
  assert_eq(directory.comment(), b"comment"[:])
  for i, entry in directory.entries() {
    assert_eq(entry.method_id(), [0, 8, 93][i])
    assert_true(entry.is_directory())
    assert_false(entry.is_encrypted())
    assert_eq(entry.creator_system(), 0)
    assert_eq(entry.external_attributes(), 0U)
    assert_eq(entry.dos_date(), 0)
    assert_eq(entry.dos_time(), 0)
    assert_true(entry.compressed_size() > 65536UL)
    assert_eq(read_member(bytes, directory, i, 701), data)
  }
}

///|
test "wrapped classic entry count remains rejected with both reader APIs" {
  let archive = Archive()
  archive.add("x", b"hello", compression=Store)
  let bytes = write(archive)
  let changed = bytes.to_fixedarray()
  // Model an EOCD whose count wrapped to zero while a directory entry remains.
  for offset in [bytes.length() - 14, bytes.length() - 12] {
    changed[offset] = 0
    changed[offset + 1] = 0
  }
  let changed = Bytes::from_array(changed)
  expect_zip_kind(() => ignore(read_all(changed)), InvalidSignature)
  expect_zip_kind(() => ignore(listing(changed)), InvalidSignature)
}
