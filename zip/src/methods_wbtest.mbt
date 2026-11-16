///|
fn listing(bytes : Bytes) -> Directory raise ZipError {
  let reader = DirectoryReader(bytes.length().to_uint64())
  for input = b"" {
    match reader.advance(input) {
      Done(directory) => return directory
      NeedRead(range) =>
        continue bytes[range.offset.to_int():range.offset.to_int() +
          range.length].to_owned()
    }
  }
}

///|
test "empty archives and members work through both reader APIs" {
  for prefix in [b"", b"SFX prefix"] {
    let empty = prefix + write(Archive())
    if prefix.length() == 0 {
      assert_eq(read_all(empty).entries().length(), 0)
      assert_eq(listing(empty).entries().length(), 0)
    } else {
      // Empty candidates must account for their entire prefix in cd_offset.
      expect_zip_kind(() => ignore(read_all(empty)), UnsupportedFeature)
      expect_zip_kind(() => ignore(listing(empty)), UnsupportedFeature)
      let adjusted = empty.to_fixedarray()
      review2_u32(
        adjusted,
        prefix.length() + 16,
        prefix.length().reinterpret_as_uint(),
      )
      let adjusted = Bytes::from_array(adjusted)
      assert_eq(read_all(adjusted).entries().length(), 0)
      assert_eq(listing(adjusted).entries().length(), 0)
    }
    let archive = Archive()
    for compression in [Store, Deflate, Zstandard] {
      archive.add("\{compression.code()}", b"", compression~)
    }
    let bytes = prefix + write(archive)
    assert_eq(read_all(bytes).entries().length(), 3)
    let directory = listing(bytes)
    for i in 0..<3 {
      assert_eq(read_member(bytes, directory, i, 1), b"")
    }
  }
  for compression in [Deflate, Zstandard] {
    assert_eq(
      decode_compressed_entry(
        compress_entry(b"", compression, 6),
        compression,
        10,
        EntryUncompressedBytes,
        10,
        () => false,
      ),
      b"",
    )
  }
}

///|
fn read_member(
  bytes : Bytes,
  directory : Directory,
  index : Int32,
  chunk : Int32,
) -> Bytes raise {
  let reader = directory.open_entry(index)
  let out = @buffer.Buffer()
  let scratch = FixedArray::make(chunk, b'\x00')
  for input = b"", steps = 0 {
    guard steps < 100000 else { fail("entry reader failed to progress") }
    let step = reader.step(input, scratch.mut_view())
    out.write_bytes(Bytes::from_array(scratch[:reader.last_produced()]))
    match step {
      Done => return out.to_bytes()
      NeedMoreOutput => continue b"", steps + 1
      NeedRead(range) =>
        continue bytes[range.offset.to_int():range.offset.to_int() +
          range.length].to_owned(),
          steps + 1
    }
  }
}

///|
test "all methods: whole, chunked, mixed entries, levels and output slices" {
  let data = Bytes::makei(10000, i => (i / 13 % 251).to_byte())
  for level in 0..<=9 {
    let archive = Archive()
    let sink = @buffer.Buffer()
    let writer = Writer(bytes => sink.write_bytes(bytes.to_owned()), level~)
    for compression in [Store, Deflate, Zstandard] {
      let name = "\{compression.code()}"
      archive.add(name, data, compression~)
      writer.add(name + "whole", data, compression~)
      writer.begin_entry(name, compression~, size=data.length().to_uint64())
      for pos = 0; pos < data.length(); pos = pos + 137 {
        writer.write(data[pos:(pos + 137).min(data.length())])
      }
      writer.end_entry()
    }
    writer.finish()
    for bytes in [write(archive, level~), sink.to_bytes()] {
      let decoded = read_all(bytes)
      let directory = listing(bytes)
      for i, entry in decoded.entries() {
        assert_eq(entry.data(), data[:])
        for chunk in [1, 31, 4096] {
          assert_eq(read_member(bytes, directory, i, chunk), data)
        }
      }
    }
  }
}

///|
test "SFX prefixes: classic, ZIP64, long comments and preservation" {
  for zip64 in [false, true] {
    let sink = @buffer.Buffer()
    let writer = Writer(bytes => sink.write_bytes(bytes.to_owned()))
    if zip64 {
      writer.begin_entry("x", compression=Zstandard)
    } else {
      writer.begin_entry("x", compression=Zstandard, size=5UL)
    }
    writer.write(b"hello")
    writer.end_entry()
    writer.finish(comment=Bytes::make(65535, b'c'))
    let plain = sink.to_bytes()
    let prefixed = b"#!/bin/sh\nexit\nMZ\x00stub" + plain
    let archive = read_all(prefixed)
    assert_eq(archive.get("x"), Some(b"hello"[:]))
    assert_eq(write(archive, preserve=true), prefixed)
    assert_eq(read_member(prefixed, listing(prefixed), 0, 1), b"hello")
    assert_true(archive.replace("x", b"edited"))
    let rewritten = write(archive, preserve=true)
    assert_eq(read_all(rewritten).get("x"), Some(b"edited"[:]))
    assert_eq(read_member(rewritten, listing(rewritten), 0, 2), b"edited")
  }
}

///|
test "shared and overlapping local records are refused before decoding" {
  let archive = Archive()
  archive.add("x", b"one", compression=Store)
  archive.add("x", b"two", compression=Store)
  let original = write(archive)
  let eocd = find_end_of_central(original).unwrap()
  let central = eocd.central_offset.reinterpret_as_int()
  let second = central + 47
  let aliased = original.to_fixedarray()
  for i in 0..<4 {
    aliased[second + 42 + i] = 0
  }
  let shared = Bytes::from_array(aliased)
  expect_zip_kind(() => ignore(read_all(shared)), UnsupportedFeature)
  expect_zip_kind(() => ignore(listing(shared)), UnsupportedFeature)
  // The first payload would include part of the second local header. Both
  // size declarations agree, so rejecting it must depend on the extents.
  let overlapping = original.to_fixedarray()
  overlapping[18] = 20
  overlapping[22] = 20
  overlapping[central + 20] = 20
  overlapping[central + 24] = 20
  let overlapping = Bytes::from_array(overlapping)
  expect_zip_kind(() => ignore(read_all(overlapping)), UnsupportedFeature)
  expect_zip_kind(() => ignore(listing(overlapping)), UnsupportedFeature)
}

///|
test "unknown compression including deferred Deflate64 is rejected before payload reads" {
  let archive = Archive()
  archive.add("x", b"hello", compression=Store)
  let plain = write(archive)
  let central = find_end_of_central(plain).unwrap().central_offset.reinterpret_as_int()
  for method_id in [9, 12, 14, 95, 65535] {
    let changed = plain.to_fixedarray()
    changed[central + 10] = (method_id & 255).to_byte()
    changed[central + 11] = (method_id >> 8).to_byte()
    // A broken local signature establishes that the method check comes first.
    changed[0] = 0
    let bytes = Bytes::from_array(changed)
    expect_zip_kind(
      () => ignore(read_all(bytes)),
      UnsupportedCompression(method_id),
    )
    let directory = listing(bytes)
    expect_zip_kind(
      () => ignore(directory.open_entry(0)),
      UnsupportedCompression(method_id),
    )
  }
}

///|
test "Zstandard codec errors retain category and range errors stay latched" {
  let archive = Archive()
  archive.add("x", Bytes::make(5000, b'x'), compression=Zstandard)
  let plain = write(archive)
  let changed = plain.to_fixedarray()
  changed[31] = 0
  let bytes = Bytes::from_array(changed)
  expect_zip_kind(
    () => ignore(read_all(bytes)),
    Codec(@codec.ErrorKind::Corrupt),
  )
  let reader = listing(bytes).open_entry(0)
  let scratch = FixedArray::make(1, b'\x00')
  for input = b"" {
    let result = reader.step(input, scratch.mut_view()) catch {
      ZipError(kind, _) => {
        assert_eq(kind, Codec(@codec.ErrorKind::Corrupt))
        assert_eq(reader.last_produced(), 0)
        expect_zip_kind(
          () => ignore(reader.step(b"", scratch.mut_view())),
          kind,
        )
        break
      }
    }
    match result {
      NeedRead(range) =>
        continue bytes[range.offset.to_int():range.offset.to_int() +
          range.length].to_owned()
      NeedMoreOutput => continue b""
      Done => fail("corrupt frame accepted")
    }
  }
}

///|
test "mutated archives produce verified data or typed ZIP errors, never abort" {
  let limits = ReadLimits(
    max_package_bytes=100000,
    max_entries=32,
    max_entry_uncompressed_bytes=20000,
    max_total_uncompressed_bytes=40000,
  )
  let mut random = 0x3528a4f1U
  for compression in [Store, Deflate, Zstandard] {
    let archive = Archive()
    archive.add("first", b"zip archive data hello", compression~)
    archive.add("second", b"more data hello", compression~)
    let original = write(archive)
    for iteration in 0..<1200 {
      let changed = original.to_fixedarray()
      random = random * 1664525U + 1013904223U
      let position = (random % changed.length().reinterpret_as_uint()).reinterpret_as_int()
      random = random * 1664525U + 1013904223U
      changed[position] = (random >> 24).to_byte()
      let bytes = Bytes::from_array(changed)
      let bytes = if iteration % 4 == 0 {
        bytes[:position].to_owned()
      } else {
        bytes
      }
      try {
        let result = read_all(bytes, limits~)
        for entry in result.entries() {
          assert_eq(entry.crc32(), @crc.crc32_update(0U, entry.data()))
        }
        let rewritten = read_all(write(result), limits~)
        assert_eq(rewritten.entries().length(), result.entries().length())
      } catch {
        ZipError(_, _) => ()
        err => raise err
      }
      try {
        let directory = listing(bytes)
        for i in 0..<directory.entries.length() {
          let reader = directory.open_entry(
            i,
            limits=EntryReadLimits(max_output_bytes=40000UL),
          )
          let scratch = FixedArray::make(37, b'\x00')
          for input = b"", steps = 0 {
            guard steps < 5000 else { fail("mutated entry failed to progress") }
            match reader.step(input, scratch.mut_view()) {
              Done => break
              NeedMoreOutput => continue b"", steps + 1
              NeedRead(range) => {
                guard range.offset <= bytes.length().to_uint64() &&
                  range.length.to_uint64() <=
                  bytes.length().to_uint64() - range.offset else {
                  fail("out of bounds range")
                }
                continue bytes[range.offset.to_int():range.offset.to_int() +
                  range.length].to_owned(),
                  steps + 1
              }
            }
          }
        }
      } catch {
        ZipError(_, _) => ()
        err => raise err
      }
    }
  }
}
