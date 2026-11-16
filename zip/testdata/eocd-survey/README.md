# EOCD survey fixtures

These eight byte-for-byte fixtures come from the supplied 2026-11-17 survey
of APPNOTE 6.3.10 and ten ZIP readers. They contain `hello.txt` (the bytes
`hello world\n` repeated 20 times) and `dir/second.txt` (`second entry\n`).

| Case | Construction |
| --- | --- |
| a | Ordinary Python Deflate archive |
| b | a + 100 deterministic garbage bytes |
| c | a + 100 zero bytes |
| d | Archive comment containing `PK\x05\x06` + 18 zero bytes |
| e | d + the same 100 garbage bytes |
| f | a with a 100-byte fake SFX stub and unadjusted offsets |
| f2 | a with the same stub, central and local offsets adjusted by 100 |
| g | Ten present comment bytes, but a declared comment length of 100 |

`src/eocd_selection_wbtest.mbt` embeds the exact bytes and checks both reader
APIs. The ordinary cases a/b/c/f/f2 also enter the generated Python oracle
catalog, whose SHA-256 values are in `../python-oracles.json`. Cases d/e are
deliberate decoys with a different policy from Python; g is malformed. The
selection rule and the reader comparison are in `docs/upstream.md` at the
repository root. No fixture is extracted during the tests.
