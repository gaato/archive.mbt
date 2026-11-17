///|
fn stored_archive_with_comment(comment : Bytes) -> Bytes raise {
  let sink = @buffer.Buffer()
  let writer = Writer(bytes => sink.write_bytes(bytes))
  writer.begin_entry("x", compression=Store)
  writer.write(b"payload")
  writer.end_entry()
  writer.finish(comment~)
  sink.to_bytes()
}

///|
fn zip64_with_extension(bytes : Bytes, extension : Bytes) -> Bytes {
  let end = find_end_of_central(bytes).unwrap().offset
  let locator = end - 20
  let record = locator - 56
  let size : Array[Byte] = []
  push_u64le(size, 44UL + extension.length().to_uint64())
  bytes[:record + 4].to_owned() +
  Bytes::from_array(size) +
  bytes[record + 12:locator].to_owned() +
  extension +
  bytes[locator:].to_owned()
}

///|
test "maximum classic comment does not probe a locator in a filename" {
  let name = "PK\u{06}\u{07}" + "a".repeat(16)
  for comment in [b"", Bytes::make(65535, b'c')] {
    let archive = Archive()
    archive.add(name, b"", compression=Store)
    archive.set_comment(comment)
    let bytes = write(archive)
    assert_eq(read_all(bytes).get(name), Some(b""[:]))
    let directory = listing(bytes)
    assert_eq(directory.entries()[0].name(), name)
    assert_eq(directory.comment(), comment[:])
    assert_eq(read_member(bytes, directory, 0, 1), b"")
    // After its tail, the range reader must probe the directory signature,
    // rather than the filename bytes immediately preceding EOCD.
    let reader = DirectoryReader(bytes.length().to_uint64())
    guard reader.advance(b"") is NeedRead(tail) else { fail("tail expected") }
    guard reader.advance(bytes[tail.offset.to_int():]) is NeedRead(range) else {
      fail("directory expected")
    }
    let end = find_end_of_central(bytes).unwrap()
    assert_eq(range.offset, end.central_offset.to_uint64())
    assert_eq(range.length, 4)
  }
}

///|
test "valid ZIP64 locator outranks an end signature in the extensible sector" {
  let fake : Array[Byte] = []
  push_u32le(fake, ZIP64_EOCD_SIG)
  push_u64le(fake, 44UL)
  fake.append(Array::make(44, b'\x00'))
  for comment in [b"", Bytes::make(65535, b'c')] {
    let bytes = zip64_with_extension(
      stored_archive_with_comment(comment),
      Bytes::from_array(fake),
    )
    assert_eq(read_all(bytes).get("x"), Some(b"payload"[:]))
    assert_eq(read_member(bytes, listing(bytes), 0, 2), b"payload")
    assert_eq(write(read_all(bytes), preserve=true), bytes)
    let reader = DirectoryReader(bytes.length().to_uint64())
    guard reader.advance(b"") is NeedRead(tail) else { fail("tail expected") }
    guard reader.advance(bytes[tail.offset.to_int():]) is NeedRead(locator) else {
      fail("locator expected")
    }
    let locator_input = bytes[locator.offset.to_int():locator.offset.to_int() +
      locator.length]
    guard reader.advance(locator_input) is NeedRead(target) else {
      fail("ZIP64 target expected")
    }
    assert_eq(target.offset, read_u64_le_at(locator_input, 8))
    guard reader.advance(
        bytes[target.offset.to_int():target.offset.to_int() + target.length],
      )
      is NeedRead(directory) else {
      fail("directory expected")
    }
    assert_eq(
      directory.offset,
      read_u64_le_at(bytes, target.offset.to_int() + 48),
    )
  }
}

///|
test "invalid ZIP64 locator target falls back to the SFX position" {
  for prefix in [b"MZ", Bytes::make(200, b'p')] {
    for comment in [b"", Bytes::make(65535, b'c')] {
      let bytes = prefix + stored_archive_with_comment(comment)
      assert_eq(read_all(bytes).get("x"), Some(b"payload"[:]))
      assert_eq(read_member(bytes, listing(bytes), 0, 3), b"payload")
      assert_eq(write(read_all(bytes), preserve=true), bytes)
    }
  }
  // A hidden locator probe without a locator must return to classic parsing.
  let archive = Archive()
  archive.add("x", b"payload", compression=Store)
  archive.set_comment(Bytes::make(65535, b'c'))
  let bytes = Bytes::make(100, b'p') + write(archive)
  assert_eq(read_all(bytes).get("x"), Some(b"payload"[:]))
  assert_eq(read_member(bytes, listing(bytes), 0, 3), b"payload")
}

///|
test "invalid ZIP64 targets and failed SFX probes remain typed errors" {
  let original = stored_archive_with_comment(b"")
  let end = find_end_of_central(original).unwrap().offset
  let record = end - 76
  for
    (field, value, expected) in [
      (record + 4, 45UL, ZipErrorKind::Truncated),
      (end - 12, 0xffff_ffff_ffff_ffffUL, ZipErrorKind::Truncated),
      (end - 16, 2UL, ZipErrorKind::Truncated),
    ] {
    let changed = original.to_fixedarray()
    let encoded : Array[Byte] = []
    push_u64le(encoded, value)
    changed.blit_from_bytesview(field, Bytes::from_array(encoded))
    let bytes = Bytes::from_array(changed)
    expect_zip_kind(() => ignore(read_all(bytes)), expected)
    expect_zip_kind(() => ignore(listing(bytes)), expected)
  }
}
