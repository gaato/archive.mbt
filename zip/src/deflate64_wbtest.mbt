///|
test "Deflate64 is read-only in whole, preserved and streaming writes" {
  assert_eq(Deflate64.code(), 9)
  let archive = Archive()
  archive.add("x", b"hello", compression=Deflate64)
  for preserve in [false, true] {
    expect_zip_kind(() => ignore(write(archive, preserve~)), InvalidArgument)
    // A source-backed method-9 entry must not bypass the write restriction.
    let source = raw_compressed_zip(
      b"hello",
      @deflate.compress(b"hello"),
      Deflate64,
    )
    let decoded = read_all(source)
    assert_eq(decoded.entries()[0].compression(), Deflate64)
    assert_eq(read_member(source, listing(source), 0, 1), b"hello")
    expect_zip_kind(() => ignore(write(decoded, preserve~)), InvalidArgument)
  }
  let sink = @buffer.Buffer()
  let writer = Writer(bytes => sink.write_bytes(bytes))
  expect_writer_error(
    () => writer.add("x", b"hello", compression=Deflate64),
    InvalidArgument,
  )
  expect_writer_error(
    () => writer.begin_entry("x", compression=Deflate64),
    InvalidArgument,
  )
  expect_writer_error(
    () => writer.begin_entry("x", compression=Deflate64, size=5UL),
    InvalidArgument,
  )
  assert_eq(sink.length(), 0)
  // Rejected arguments do not open an entry or poison the writer.
  writer.add("ok", b"hello", compression=Store)
  writer.finish()
  assert_eq(read_all(sink.to_bytes()).get("ok"), Some(b"hello"[:]))
  expect_zip_kind(() => ignore(entry_encoder(Deflate64, 6)), InvalidArgument)
  expect_zip_kind(
    () => ignore(compress_entry(b"hello", Deflate64, 6)),
    InvalidArgument,
  )
  assert_eq(@deflate64.decoder_memory_bound(), 79384L)
}

///|
test "Deflate levels 10 through 12 pass unchanged through all writer paths" {
  let words = [
    b"zip ", b"entry ", b"declared ", b"size ", b"deflate ", b"payload ", b"central ",
    b"local ",
  ]
  let out = @buffer.Buffer()
  let mut state = 0x2545f491U
  while out.length() < 5000 {
    state = state * 1103515245U + 12345U
    out.write_bytes(words[((state >> 16) & 7).reinterpret_as_int()])
  }
  let data = out.to_bytes()[:5000].to_owned()
  assert_true(
    @deflate.compress(data, level=12) != @deflate.compress(data, level=9),
  )
  for level in 10..<=12 {
    let expected = @deflate.compress(data, level~)
    let archive = Archive()
    archive.add("x", data)
    let sink = @buffer.Buffer()
    let writer = Writer(bytes => sink.write_bytes(bytes), level~)
    writer.add("whole", data)
    writer.begin_entry("chunked", size=data.length().to_uint64())
    for start = 0; start < data.length(); start = start + 53 {
      writer.write(data[start:(start + 53).min(data.length())])
    }
    writer.end_entry()
    writer.finish()
    for bytes in [write(archive, level~), sink.to_bytes()] {
      let decoded = read_all(bytes)
      let directory = listing(bytes)
      for i, entry in decoded.entries() {
        assert_eq(entry.data(), data[:])
        // This also verifies the level was not silently clamped by ZIP.
        let header = entry.source.unwrap().local_record
        let start = 30 + read_u16_le_at(header, 26) + read_u16_le_at(header, 28)
        assert_eq(header[start:start + entry.compressed_size], expected[:])
        assert_eq(read_member(bytes, directory, i, 37), data)
      }
    }
  }
}
