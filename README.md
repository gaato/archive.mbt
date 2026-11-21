# archive.mbt

Archive formats in pure MoonBit, for Native, JS, Wasm and Wasm GC. The
compression inside an archive comes from the codecs of
[codecs.mbt](https://github.com/gaato/codecs.mbt), so an archive module only
reads and writes the container.

[日本語](README.ja.md)

| Module | What it is | Directory |
|---|---|---|
| [`gaato/zip`](https://mooncakes.io/docs/gaato/zip) | ZIP archives: Store, Deflate and Zstandard, Deflate64 read only, ZIP64. Edit an archive in memory, read one entry through byte ranges, or stream a new archive to a sink, with limits on what an untrusted archive may expand to | [`zip/`](zip/) |

`gaato/zip` started as a port of MoonBit core's `archive/zip`;
[docs/upstream.md](docs/upstream.md) records what was ported, what changed and
why.

## TODO

- [ ] tar
  - [ ] Reading
  - [ ] Writing
  - [ ] `.tar.gz` and `.tar.zst`, through the codecs of [codecs.mbt](https://github.com/gaato/codecs.mbt)
  - [ ] `.tar.xz`, once [codecs.mbt](https://github.com/gaato/codecs.mbt) has xz
- [ ] bzip2 entries in ZIP, once [codecs.mbt](https://github.com/gaato/codecs.mbt) has bzip2.

Bugs and requests go to [Issues](https://github.com/gaato/archive.mbt/issues).

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
