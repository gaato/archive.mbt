///|
fn directory_by_ranges(
  bytes : Bytes,
  limits : DirectoryLimits,
) -> Directory raise ZipError {
  let reader = DirectoryReader(bytes.length().to_uint64(), limits~)
  for input = (b"" : BytesView) {
    match reader.advance(input) {
      Done(directory) => return directory
      NeedRead(range) =>
        continue bytes[range.offset.to_int():range.offset.to_int() +
          range.length]
    }
  }
}

///|
test "agreeing ZIP64 prefix decoy retries classic before limits" {
  let locator = @buffer.Buffer()
  locator.write_uint_le(ZIP64_LOCATOR_SIG)
  locator.write_uint_le(0U)
  locator.write_uint64_le(123UL)
  locator.write_uint_le(1U)
  let name = @encoding/utf8.decode(locator.to_bytes())
  for comment in [b"", Bytes::make(65535, b'c')] {
    for fake_header in [b"pppp", b"PK\x01\x02"] {
      let archive = Archive()
      archive.add(name, b"payload", compression=Store)
      archive.set_comment(comment)
      let plain = write(archive)
      let end = 512 + plain.length() - 22 - comment.length()
      let prefix = @buffer.Buffer()
      // With PK at 57 the false ZIP64 directory passes the tier probe but
      // fails full parsing; classic must be probed again and still succeed.
      prefix.write_bytes(Bytes::make(57, b'p'))
      prefix.write_bytes(fake_header)
      prefix.write_bytes(Bytes::make(62, b'p'))
      prefix.write_uint_le(ZIP64_EOCD_SIG)
      prefix.write_uint64_le(end.to_uint64() - 20UL - 123UL - 12UL)
      prefix.write_uint16_le((45).to_uint16())
      prefix.write_uint16_le((45).to_uint16())
      prefix.write_uint_le(0U)
      prefix.write_uint_le(0U)
      prefix.write_uint64_le(1UL)
      prefix.write_uint64_le(1UL)
      prefix.write_uint64_le(66UL)
      prefix.write_uint64_le(57UL)
      prefix.write_bytes(Bytes::make(512 - prefix.length(), b'p'))
      let bytes = prefix.to_bytes() + plain
      assert_eq(
        read_all(
          bytes,
          limits=ReadLimits(
            max_entries=1,
            max_entry_uncompressed_bytes=7,
            max_total_uncompressed_bytes=7,
          ),
        ).get(name),
        Some(b"payload"[:]),
      )
      let directory = directory_by_ranges(
        bytes,
        DirectoryLimits(max_entries=1UL, max_directory_bytes=66UL),
      )
      assert_eq(directory.entries()[0].name(), name)
      assert_eq(read_member(bytes, directory, 0, 1), b"payload")
    }
  }
}

///|
test "adjusted empty comment decoy is ambiguous" {
  for prefix in [b"", Bytes::make(100, b'p')] {
    let archive = Archive()
    archive.add("x", b"payload", compression=Store)
    archive.set_comment(b"PK\x05\x06" + Bytes::make(18, 0))
    let bytes = prefix + write(archive)
    let changed = bytes.to_fixedarray()
    write_u32_at(
      changed,
      bytes.length() - 6,
      (bytes.length() - 22).reinterpret_as_uint(),
    )
    let bytes = Bytes::from_array(changed)
    // Both candidates now satisfy the agreed structural selection rule.
    expect_zip_kind(() => ignore(read_all(bytes)), Corrupt)
    expect_zip_kind(() => ignore(listing(bytes)), Corrupt)
  }
}

///|
test "comment decoy limits cannot block the real EOCD" {
  let archive = Archive()
  archive.add("x", b"payload", compression=Store)
  archive.set_comment(b"PK\x05\x06" + Bytes::make(18, 0))
  let bytes = Bytes::make(100, b'p') + write(archive)
  let changed = bytes.to_fixedarray()
  let decoy = bytes.length() - 22
  changed[decoy + 8] = 0xe8
  changed[decoy + 9] = 3
  changed[decoy + 10] = 0xe8
  changed[decoy + 11] = 3
  write_u32_at(changed, decoy + 12, 47U)
  write_u32_at(changed, decoy + 16, (decoy - 47).reinterpret_as_uint())
  let bytes = Bytes::from_array(changed)
  assert_eq(
    read_all(
      bytes,
      limits=ReadLimits(
        max_entries=1,
        max_entry_uncompressed_bytes=7,
        max_total_uncompressed_bytes=7,
      ),
    ).get("x"),
    Some(b"payload"[:]),
  )
  let directory = directory_by_ranges(
    bytes,
    DirectoryLimits(max_entries=1UL, max_directory_bytes=47UL),
  )
  assert_eq(read_member(bytes, directory, 0, 1), b"payload")
}

///|
test "concatenated archives prefer tier 1 and trailing data uses tier 2" {
  let first = Archive()
  first.add("first", b"one", compression=Store)
  let second = Archive()
  second.add("second", b"two", compression=Store)
  let bytes = write(first) + write(second)
  assert_eq(read_all(bytes).entries()[0].name(), "second")
  assert_eq(read_member(bytes, listing(bytes), 0, 1), b"two")
  let appended = write(first) + b"garbage"
  assert_eq(read_all(appended).get("first"), Some(b"one"[:]))
  assert_eq(read_member(appended, listing(appended), 0, 1), b"one")
}
