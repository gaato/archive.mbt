# archive.mbt

純粋な MoonBit で書いたアーカイブ形式のモジュール集です。Native・JS・Wasm・Wasm GC で動きます。アーカイブの中の圧縮は [codecs.mbt](https://github.com/gaato/codecs.mbt) のコーデックが受け持つので、アーカイブのモジュールは入れ物の読み書きだけを行います。

[English](README.md)

| モジュール | 中身 | ディレクトリ |
|---|---|---|
| [`gaato/zip`](https://mooncakes.io/docs/gaato/zip) | ZIP アーカイブ。Store・Deflate・Zstandard、Deflate64 は読むだけ、ZIP64 にも対応。メモリ上での編集、必要なバイト範囲だけを取り寄せての一つのエントリーの読み込み、書き出し先へ流しながらの新しいアーカイブの作成ができ、信頼できないアーカイブが展開しうる大きさに上限を設けられる | [`zip/`](zip/) |

`gaato/zip` は MoonBit core の `archive/zip` の移植から始まりました。何を移植し、何をなぜ変えたかは [docs/upstream.md](docs/upstream.md) にあります。

## TODO

- [ ] tar
  - [ ] 読み込み
  - [ ] 書き出し
  - [ ] [codecs.mbt](https://github.com/gaato/codecs.mbt) のコーデックによる `.tar.gz` と `.tar.zst`
  - [ ] `.tar.xz`。[codecs.mbt](https://github.com/gaato/codecs.mbt) に xz ができてから
- [ ] ZIP の bzip2 方式。[codecs.mbt](https://github.com/gaato/codecs.mbt) に bzip2 ができてから。

不具合や要望は [Issues](https://github.com/gaato/archive.mbt/issues) へどうぞ。

## ライセンス

Apache-2.0 です。[LICENSE](LICENSE) と [NOTICE](NOTICE) を参照してください。
