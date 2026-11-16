///|
fn fresh_stream(
  data : Bytes,
  compression : Compression,
  level : Int32,
) -> Bytes raise {
  if compression is Store {
    return data
  }
  let encoder = entry_encoder(compression, level)
  let scratch = FixedArray::make(37, b'\x00')
  let out = @buffer.Buffer()
  for position = 0 {
    let status = encoder.step(
      data[position:],
      scratch.mut_view(),
      action=Finish,
    )
    out.write_bytes(
      borrowed_zip_buffer_bytes(scratch)[:encoder.last_produced()],
    )
    let position = position + encoder.last_consumed()
    match status {
      Done => {
        assert_eq(position, data.length())
        break
      }
      NeedMoreOutput => continue position
      NeedMoreInput => fail("Finish must complete the stream")
    }
  }
  out.to_bytes()
}

///|
test "chunked encoders and scratch are reused across method switches without changing bytes" {
  let methods = [
    Deflate,
    Deflate,
    Store,
    Zstandard,
    Zstandard,
    Deflate,
    Store,
    Zstandard,
  ]
  let data = [
    b"",
    Bytes::make(9000, b'x'),
    Bytes::makei(140000, i => (i / 7 % 251).to_byte()),
  ]
  for level in 0..<=9 {
    let sink = @buffer.Buffer()
    let writer = Writer(bytes => sink.write_bytes(bytes), level~)
    let expected : Array[Bytes] = []
    let mut first_deflate : &@codec_bytes.Encode? = None
    let mut first_zstd : &@codec_bytes.Encode? = None
    let mut scratch : FixedArray[Byte]? = None
    for i, compression in methods {
      let payload = data[i % data.length()]
      expected.push(fresh_stream(payload, compression, level))
      writer.begin_entry("\{i}", compression~)
      if !(compression is Store) {
        let encoder = writer.deflater.unwrap()
        let previous = if compression is Deflate {
          first_deflate
        } else {
          first_zstd
        }
        if previous is Some(previous) {
          assert_true(@builtin.physical_equal(encoder, previous))
        } else if compression is Deflate {
          first_deflate = Some(encoder)
        } else {
          first_zstd = Some(encoder)
        }
        if scratch is Some(previous) {
          assert_true(@builtin.physical_equal(writer.scratch, previous))
        } else {
          scratch = Some(writer.scratch)
        }
        assert_eq(writer.scratch.length(), 65536)
      }
      for offset = 0; offset < payload.length(); offset = offset + 101 {
        writer.write(payload[offset:(offset + 101).min(payload.length())])
      }
      writer.end_entry()
    }
    writer.finish()
    assert_true(writer.deflate_encoder is None)
    assert_true(writer.zstd_encoder is None)
    assert_true(writer.scratch.is_empty())
    let bytes = sink.to_bytes()
    let end = parse_end_of_central(bytes, ReadLimits(), () => false)
    let entries = parse_central_directory(bytes, end, ReadLimits(), () => false)
    for i, entry in entries {
      assert_eq(
        read_local_record(bytes, entry, end.central_offset).compressed,
        expected[i][:],
      )
    }
    assert_eq(read_all(bytes).entries().length(), methods.length())
  }
}

///|
test "direct decode views handle growth, exact output and understated declarations" {
  for compression in [Deflate, Zstandard] {
    for size in [0, 1, 4095, 4096, 4097, 8192, 65536, 65537] {
      let data = Bytes::makei(size, i => (i % 251).to_byte())
      let raw = compress_entry(data, compression, 6)
      for declared in [size, size + 1, (size - 1).max(0)] {
        assert_eq(
          inflate_declared_entry(
            raw,
            declared,
            size + 1,
            EntryUncompressedBytes,
            size + 1,
            () => false,
            compression~,
          ),
          data,
        )
      }
    }
  }
}

///|
test "sink failure releases both cached encoders and the shared scratch" {
  let mut fail_sink = false
  let writer = Writer(_ => if fail_sink { raise StreamSinkFailure(42) })
  for compression in [Deflate, Zstandard] {
    writer.begin_entry("x", compression~)
    writer.write(b"payload")
    writer.end_entry()
  }
  assert_true(writer.deflate_encoder is Some(_))
  assert_true(writer.zstd_encoder is Some(_))
  assert_eq(writer.scratch.length(), 65536)
  fail_sink = true
  try writer.begin_entry("failure") catch {
    StreamSinkFailure(code) => assert_eq(code, 42)
    err => raise err
  } noraise {
    _ => fail("sink error expected")
  }
  assert_true(writer.is_failed())
  assert_true(writer.deflater is None)
  assert_true(writer.deflate_encoder is None)
  assert_true(writer.zstd_encoder is None)
  assert_true(writer.scratch.is_empty())
  assert_true(writer.directory.is_empty())
}
