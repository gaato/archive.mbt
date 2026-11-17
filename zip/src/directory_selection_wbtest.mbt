///|
fn write_u32_at(
  bytes : FixedArray[Byte],
  offset : Int32,
  value : UInt32,
) -> Unit {
  for i in 0..<4 {
    bytes[offset + i] = (value >> (8 * i)).to_byte()
  }
}

///|
test "prefixed classic locator-like filenames stay classic" {
  let names = [
    "PK\u{06}\u{07}" + "a".repeat(16),
    "PK\u{06}\u{07}" + "\u{00}".repeat(12) + "\u{01}\u{00}\u{00}\u{00}",
  ]
  for name in names {
    for comment in [b"", Bytes::make(65535, b'c')] {
      let archive = Archive()
      archive.add(name, b"", compression=Store)
      archive.set_comment(comment)
      for prefix in [b"", Bytes::make(100, b'p'), Bytes::make(512, b'p')] {
        let bytes = prefix + write(archive)
        assert_eq(read_all(bytes).get(name), Some(b""[:]))
        let directory = listing(bytes)
        assert_eq(directory.entries()[0].name(), name)
        assert_eq(read_member(bytes, directory, 0, 1), b"")
        assert_eq(write(read_all(bytes), preserve=true), bytes)
      }
    }
  }
}

///|
test "earliest EOF-reaching EOCD survives later adjacent decoys" {
  let decoy = b"PK\x05\x06" + Bytes::make(18, 0)
  for prefix in [b"", Bytes::make(100, b'p')] {
    let archive = Archive()
    archive.add("x", b"payload", compression=Store)
    archive.set_comment(decoy)
    let bytes = prefix + write(archive)
    assert_eq(read_all(bytes).get("x"), Some(b"payload"[:]))
    assert_eq(read_member(bytes, listing(bytes), 0, 1), b"payload")
    expect_zip_kind(
      () => ignore(read_all(bytes, limits=ReadLimits(max_entries=0))),
      LimitExceeded(kind=Entries, limit=0UL, observed=1UL),
    )
    expect_zip_kind(
      () => ignore(directory_by_ranges(bytes, DirectoryLimits(max_entries=0UL))),
      LimitExceeded(kind=Entries, limit=0UL, observed=1UL),
    )
    // Even a comment decoy claiming an adjacent directory cannot replace
    // the earlier real EOCD, including with an SFX prefix.
    let changed = bytes.to_fixedarray()
    let fake = bytes.length() - 22
    changed[fake + 8] = 1
    changed[fake + 10] = 1
    write_u32_at(changed, fake + 12, 46U)
    write_u32_at(changed, fake + 16, (fake - 46).reinterpret_as_uint())
    let bytes = Bytes::from_array(changed)
    assert_eq(read_all(bytes).get("x"), Some(b"payload"[:]))
    assert_eq(read_member(bytes, listing(bytes), 0, 1), b"payload")
  }
}

///|
test "two signature-valid directories are ambiguous before extent checks" {
  let archive = Archive()
  archive.add("x", b"payload", compression=Store)
  let plain = write(archive)
  let end = plain.length() - 22
  let central = read_u32_le_at_raw(plain, end + 16).reinterpret_as_int()
  let entry = plain[central:end].to_owned().to_fixedarray()
  write_u32_at(entry, 42, 100U)
  let entry = Bytes::from_array(entry)
  let decoy = classic_eocd(0, 0, 2, 2, entry.length() * 2, 100 + end + 22)
  archive.set_comment(entry + entry + decoy)
  let bytes = Bytes::make(100, b'p') + write(archive)
  // Selection probes signatures and nonnegative archive starts; it does not
  // parse every candidate's entries. Both EOF-reaching candidates pass.
  expect_zip_kind(() => ignore(read_all(bytes)), Corrupt)
  expect_zip_kind(() => ignore(listing(bytes)), Corrupt)
  // Once the real signature is broken, the decoy is uniquely selected; the
  // subsequent full directory parse still refuses its shared extents.
  let changed = bytes.to_fixedarray()
  changed[100 + central] = 0
  let changed = Bytes::from_array(changed)
  expect_zip_kind(() => ignore(read_all(changed)), UnsupportedFeature)
  expect_zip_kind(() => ignore(listing(changed)), UnsupportedFeature)
}

///|
test "a real locator target with conflicting classic fields stays classic" {
  for
    (count, size, offset) in [
      (2UL, 66UL, 50UL),
      (1UL, 67UL, 50UL),
      (1UL, 66UL, 51UL),
    ] {
    let target = size + offset
    let locator = @buffer.Buffer()
    locator.write_uint_le(ZIP64_LOCATOR_SIG)
    locator.write_uint_le(0U)
    locator.write_uint64_le(target)
    locator.write_uint_le(1U)
    let name = @encoding/utf8.decode(locator.to_bytes())
    for comment in [b"", Bytes::make(65535, b'c')] {
      let archive = Archive()
      archive.add(name, b"", compression=Store)
      archive.set_comment(comment)
      let plain = write(archive)
      let real_end = 512 + plain.length() - 22 - comment.length()
      let prefix = @buffer.Buffer()
      prefix.write_bytes(Bytes::make(target.to_int(), b'p'))
      prefix.write_uint_le(ZIP64_EOCD_SIG)
      prefix.write_uint64_le(real_end.to_uint64() - 20UL - target - 12UL)
      prefix.write_uint16_le((45).to_uint16())
      prefix.write_uint16_le((45).to_uint16())
      prefix.write_uint_le(0U)
      prefix.write_uint_le(0U)
      prefix.write_uint64_le(count)
      prefix.write_uint64_le(count)
      prefix.write_uint64_le(size)
      prefix.write_uint64_le(offset)
      prefix.write_bytes(Bytes::make(512 - prefix.length(), b'p'))
      let bytes = prefix.to_bytes() + plain
      assert_eq(read_all(bytes).get(name), Some(b""[:]))
      assert_eq(read_member(bytes, listing(bytes), 0, 1), b"")
    }
  }
}

///|
test "eager and range readers skip framed directory signatures" {
  for size in [0, 8, 65535] {
    let signature = @buffer.Buffer()
    signature.write_uint_le(DIRECTORY_SIGNATURE_SIG)
    signature.write_uint16_le(size.to_uint16())
    signature.write_bytes(Bytes::make(size, b's'))
    let signature = signature.to_bytes()
    for comment in [b"", b"PK\x05\x06" + Bytes::make(18, 0)] {
      let archive = Archive()
      archive.add("x", b"payload", compression=Store)
      archive.set_comment(comment)
      let plain = write(archive)
      let end = plain.length() - 22 - comment.length()
      let bytes = plain[:end].to_owned() + signature + plain[end:].to_owned()
      let changed = bytes.to_fixedarray()
      write_u32_at(
        changed,
        end + signature.length() + 12,
        (47 + signature.length()).reinterpret_as_uint(),
      )
      for prefix in [b"", Bytes::make(100, b'p')] {
        let bytes = prefix + Bytes::from_array(changed)
        assert_eq(read_all(bytes).get("x"), Some(b"payload"[:]))
        assert_eq(read_member(bytes, listing(bytes), 0, 1), b"payload")
        assert_eq(write(read_all(bytes), preserve=true), bytes)
      }
      if size == 8 && comment.is_empty() {
        changed[end + 4] = 9
        let malformed = Bytes::from_array(changed)
        expect_zip_kind(() => ignore(read_all(malformed)), UnsupportedFeature)
        expect_zip_kind(() => ignore(listing(malformed)), UnsupportedFeature)
      }
    }
  }
}
