///|
fn main raise {
  let data = b"Archive interop: Store, Deflate, Zstandard.\n".repeat(32)
  for
    (label, compression, level) in [
      ("store", @zip.Store, 6),
      ("deflate", @zip.Deflate, 6),
      ("zstd", @zip.Zstandard, 6),
      ("deflate12", @zip.Deflate, 12),
    ] {
    let archive = @zip.Archive()
    archive.add("payload.txt", data, compression~)
    println("\{label}-whole \{@hex.encode(@zip.write(archive, level~))}")
    for known_size in [true, false] {
      let sink = @buffer.Buffer()
      let writer = @zip.Writer(
        bytes => sink.write_bytes(bytes.to_owned()),
        level~,
      )
      if known_size {
        writer.begin_entry(
          "payload.txt",
          compression~,
          size=data.length().to_uint64(),
        )
      } else {
        writer.begin_entry("payload.txt", compression~)
      }
      for position = 0; position < data.length(); position = position + 7 {
        writer.write(data[position:(position + 7).min(data.length())])
      }
      writer.end_entry()
      writer.finish()
      println(
        "\{label}-\{if known_size { "classic" } else { "zip64" }} \{@hex.encode(sink.to_bytes())}",
      )
    }
  }
}
