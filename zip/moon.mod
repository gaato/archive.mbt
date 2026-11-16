name = "gaato/zip"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/archive.mbt"

description = "Bounded ZIP archives with Store, Deflate and Zstandard, in pure MoonBit."

keywords = [ "zip", "archive", "deflate", "zstandard" ]

source = "src"

preferred_target = "native"

supported_targets = "js + native + wasm + wasm-gc"

import {
  "gaato/deflate@0.3.0",
  "gaato/zstd@0.5.1",
  "gaato/crc@0.1.0",
  "gaato/codec@0.1.1",
  "gaato/codec_bytes@0.1.2",
}
