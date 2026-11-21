# gaato/zip

Create, read and edit ZIP archives in pure MoonBit, for Native, JS, Wasm and
Wasm GC. Use it to build a ZIP for download, to read an uploaded archive with
limits on what it may expand to, or to read one entry of a large or remote
ZIP by fetching only the byte ranges it needs.

- Store and Deflate, which every ZIP tool reads, plus Zstandard (method 93) for
  readers that support it. Deflate64 (method 9) is read only.
- ZIP64, for archives and entries over 4 GiB.
- Three ways to work: an `Archive` in memory, range readers that ask you for
  bytes, and a `Writer` that streams to a sink you provide.

The in-memory API follows MoonBit core's `archive/zip`.

## Install

```sh
moon add gaato/zip
```

## Create, read and edit an archive in memory

```mbt check
///|
test "create, read, edit and rewrite a ZIP" {
  let archive = @zip.Archive()
  archive.add("hello.txt", b"hello", compression=Deflate)
  let bytes = @zip.write(archive)
  let decoded = @zip.read_all(
    bytes,
    limits=@zip.ReadLimits(
      max_package_bytes=1024 * 1024,
      max_entries=100,
      max_entry_uncompressed_bytes=1024 * 1024,
      max_total_uncompressed_bytes=4 * 1024 * 1024,
    ),
  )
  assert_eq(decoded.get("hello.txt"), Some(b"hello"[:]))
  assert_true(decoded.replace("hello.txt", b"updated"))
  assert_eq(
    @zip.read_all(@zip.write(decoded)).get("hello.txt"),
    Some(b"updated"[:]),
  )
}
```

**Set `ReadLimits` for any archive from someone else.** Without them,
`read_all` accepts anything up to what an in-memory array holds, and a small
ZIP can expand to gigabytes.

`write(archive, preserve=true)` reuses the records of unchanged entries, so an
archive read and written back unchanged is identical byte for byte,
self-extracting prefix included.

## Read one entry without downloading the archive

`DirectoryReader` and `EntryReader` never read on their own. They return
`NeedRead(range)`, and you answer with exactly those bytes, from a file, a
cache or an HTTP `Range` request. In the example, `fetch` slices a buffer, but
it can be any source that returns the same immutable bytes every time.

```mbt check
///|
/// Reads the entry called `name` from a ZIP of `size` bytes, fetching only the
/// ranges the readers ask for.
fn read_entry(
  size : UInt64,
  fetch : (@zip.ReadRange) -> BytesView,
  name : String,
) -> Bytes? raise @zip.ZipError {
  let lister = @zip.DirectoryReader(
    size,
    limits=@zip.DirectoryLimits(max_entries=10000UL),
  )
  let directory = for input = (b"" : BytesView) {
    match lister.advance(input) {
      NeedRead(range) => continue fetch(range)
      Done(directory) => break directory
    }
  }
  let entries = directory.entries()
  let mut index = -1
  for i in 0..<entries.length() {
    if entries[i].name() == name {
      index = i
      break
    }
  }
  guard index >= 0 else { return None }
  let reader = directory.open_entry(
    index,
    limits=@zip.EntryReadLimits(max_output_bytes=1UL << 20),
  )
  let out = FixedArray::make(64 * 1024, b'\x00')
  let content = Buffer()
  let bytes = for input = (b"" : BytesView) {
    let status = reader.step(input, out.mut_view())
    // Every step may produce output, `Done` included.
    content.write_bytes(Bytes::from_array(out[:reader.last_produced()]))
    match status {
      NeedRead(range) => continue fetch(range)
      NeedMoreOutput => continue b""
      Done => break content.to_bytes()
    }
  }
  Some(bytes)
}

///|
test "read one entry through ranges" {
  let archive = @zip.Archive()
  archive.add("manifest.json", b"{\"version\":1}", compression=Deflate)
  archive.add("data.bin", Bytes::make(4096, b'x'), compression=Store)
  let zip = @zip.write(archive)
  let fetch = fn(range : @zip.ReadRange) -> BytesView {
    let offset = range.offset().to_int()
    zip[offset:offset + range.length()]
  }
  assert_eq(
    read_entry(zip.length().to_uint64(), fetch, "manifest.json"),
    Some(b"{\"version\":1}"),
  )
}
```

The listing reads only the central directory, and it includes encrypted entries
and unknown methods without reading their data. `open_entry` refuses those
before any read. An entry's output is not verified until `Done` has checked
its size and CRC, so commit it only then.

## Write to a sink

`Writer` takes a function that receives the archive's bytes as they are
written, such as an HTTP response body or a file. Use `add` for a file you
hold whole, or `begin_entry`, `write` and `end_entry` for one that arrives in
pieces, then `finish` to write the directory. If the sink raises, the writer
stops and every later call raises.

```mbt check
///|
test "stream an archive to a sink" {
  let sink = Buffer()
  let writer = @zip.Writer(bytes => sink.write_bytesview(bytes))
  writer.add("readme.txt", b"read me", compression=Deflate)
  writer.begin_entry("log.txt", compression=Deflate)
  for line in [b"one\n", b"two\n"] {
    writer.write(line)
  }
  writer.end_entry()
  writer.finish()
  let archive = @zip.read_all(sink.to_bytes())
  assert_eq(archive.get("log.txt"), Some(b"one\ntwo\n"[:]))
}
```

## Choosing a compression method

| `compression=` | Read by | Notes |
| --- | --- | --- |
| `Deflate` | Every ZIP tool | The usual choice. |
| `Store` | Every ZIP tool | No compression. Use it for data that is already compressed (images, video, other archives). |
| `Zstandard` | Only readers that support method 93 | Often smaller and faster to read, but check that your recipients' tools can open it. |
| `Deflate64` | — | Read only. Writing it raises `InvalidArgument`. |

`level` on `write` and `Writer` is 6 by default and goes to the chosen codec:
0–12 for Deflate (10–12 search hardest), and up to 22 for Zstandard. Zstandard
levels above 12 use much more memory.

## Limits

| Limit | Applies to | Default |
| --- | --- | --- |
| `ReadLimits(max_package_bytes~, max_entries~, max_entry_uncompressed_bytes~, max_total_uncompressed_bytes~)` | `read_all` | What an in-memory array holds |
| `DirectoryLimits(max_directory_bytes~, max_entries~)` | `DirectoryReader` | None |
| `EntryReadLimits(max_output_bytes~)` | `open_entry` | None |
| `max_output_bytes` | `write` | Bounds the returned buffer only, not working memory |

`read_all` takes `cancelled=` and polls it. Range readers are cancelled by not
calling the next step.

## Errors

Failures raise `ZipError(kind, message)`. Branch on the kind. The message is
for people.

- `LimitExceeded(kind~, limit~, observed~)`: a limit above was reached, and
  `kind` names which one.
- `Codec(kind)`: the compressed data is bad. `kind` is the codec's
  [`gaato/codec`](https://mooncakes.io/docs/gaato/codec) `ErrorKind`, such as
  `Corrupt` or `Truncated`.
- `SizeMismatch`, `ChecksumMismatch`: an entry's data does not match its
  record.
- `UnsupportedCompression(method)`, `UnsupportedFeature`: encryption, split
  archives or a method this module does not read.
- `Corrupt`, `Truncated`, `InvalidSignature`, `MissingEndOfCentral`: the
  archive's structure is broken. Overlapping or shared entry records are refused
  as `Corrupt`.
- `InvalidRead(expected~, actual~)`: a range answer of the wrong length.
- `Cancelled`, `InvalidArgument`, `InvalidState`, `InvalidEntryIndex`,
  `InvalidUtf8`.

## What this module does not do

- **It does not write files to disk.** It hands you names and bytes. If you
  extract to a filesystem, reject `../`, absolute paths and symlinks yourself.
- Encryption, split archives, and names that are not UTF-8 are not supported.

Archives with prepended data (self-extracting archives) and trailing data are
read. How the end-of-directory record is located, and how that compares with
other readers, is documented in
[upstream and port decisions](https://github.com/gaato/archive.mbt/blob/main/docs/upstream.md).

## Links

- [Resource bounds](https://github.com/gaato/archive.mbt/blob/main/zip/RESOURCE_BOUNDS.md)
- [Test coverage](https://github.com/gaato/archive.mbt/blob/main/zip/TEST_COVERAGE.md)
- [Upstream and port decisions](https://github.com/gaato/archive.mbt/blob/main/docs/upstream.md)
- [Changelog](https://github.com/gaato/archive.mbt/blob/main/zip/CHANGELOG.md)

## License

Apache-2.0. Derived from MoonBit core's `archive/zip`, copyright 2026
International Digital Economy Academy. See the repository's
[LICENSE](https://github.com/gaato/archive.mbt/blob/main/LICENSE) and
[NOTICE](https://github.com/gaato/archive.mbt/blob/main/NOTICE).
