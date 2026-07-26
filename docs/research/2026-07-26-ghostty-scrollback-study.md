# Ghostty scrollback compaction study

Date: 2026-07-26

Reference checkout:
`/home/reklai/coding/personal/ts_js/ghostty` at
`15484b607eb5a518dedf1548247c923b8abaae7c`.

Primary sources:

- [Ghostty scrollback compression pull request][ghostty-pr]
- [PageList storage and traversal][pagelist]
- [PageList compression scheduler][pagelist-compression]
- [Page codec][page-codec]
- [Renderer idle scheduling][renderer]
- [Platform memory reclamation][memory]
- [LZ4 block format][lz4]
- [Scrollback compression demo][demo]

## What Ghostty actually does

Ghostty does not compress one monolithic scrollback string. Its scrollback is a
linked list of independently owned pages. A page remains structurally
traversable while its content is either resident or compressed; an accessor
restores content transparently when a caller genuinely needs it.

Compression is deliberately incremental:

- Only complete historical pages outside the active or visible region are
  candidates.
- Traversal is serial-aware and restarts safely after mutations.
- One scheduler step inspects at most eight candidates and attempts at most one
  compression.
- A verification pass catches missed work without turning normal input into a
  full-history scan.
- Compression runs only after an activity-token idle debounce. Pending work is
  resumed in short steps, and a contended lock is skipped rather than blocking
  the renderer.

Each eligible page is encoded with raw, allocation-free LZ4. The decoded byte
size is known exactly. A page keeps the compressed representation only when
the complete replacement is strictly smaller than the resident representation.
Linux and macOS then use their respective advisory memory APIs to release
physical backing while retaining a reusable virtual mapping.

The pull request reports a repetitive 121-page corpus shrinking from about
49.56 MiB to 3.03 MiB (6.11% of the original), with roughly 101 microseconds
per-page compression and 26 microseconds per-page restoration. It describes
ordinary text ratios as commonly landing around 10–30%. Those numbers are
Ghostty measurements, not CanvasDiff promises.

## What transfers to CanvasDiff

The reusable ideas are architectural:

1. Page the logical document; never require a whole-document decode to draw a
   viewport.
2. Keep page identity, row ranges, lengths, checksums, and state resident while
   allowing payloads to become cold.
3. Restore through one checked accessor so callers cannot accidentally use a
   compressed payload.
4. Compact only cold, unpinned pages.
5. Bound work per scheduler tick and restart safely after structural mutation.
6. Prefer no compression over a representation that is larger or unverifiable.
7. Treat decoding failure as a contained page fault, never as undefined text.
8. Measure steady-state interaction separately from one-time ingestion.

## What does not transfer directly

Neovim owns its buffer storage, renderer, event loop, and allocator. A Lua
plugin cannot apply Ghostty's `madvise` strategy to arbitrary Neovim memline
pages, nor can it replace terminal-grid cells with Ghostty's native page
representation.

Repeatedly replacing a viewport-sized slice of real buffer text is also a bad
substitute. The local prototype stayed fast per splice, but Neovim's allocator
high-water mark grew from roughly 22 MiB to 177.5 MiB over 1,600 random jumps.

The viable transfer is therefore a logical page store plus a cheap skeleton
buffer:

- The buffer contains one blank native row per logical row, preserving native
  vertical scrolling and exact line count.
- A decoration provider supplies visible text with ephemeral virtual text.
- An `on_win` callback preloads the few pages needed by the viewport.
- An `on_range` callback performs only bounded, synchronous lookups and emits
  ephemeral marks.
- Search, yank, selection, horizontal positioning, and text export operate on
  the logical store because virtual text is not buffer text.
- A small selected-page materialization mode may be added only where Neovim
  semantics cannot be reproduced honestly.

## Local feasibility results

Two disposable prototypes were run with Neovim 0.12.4, LuaJIT, and liblz4 1.10.
They are evidence for the production design, not shipped code.

The page-store prototype used 256-row pages for one million 80-byte rows:

| Corpus | Build | Stored payload | Lookup | Random page update |
| --- | ---: | ---: | ---: | ---: |
| repetitive | 124.7 ms | 4.28 MiB / 80.12 MiB (5.34%) | 142 ns | 0.74–0.88 ms |
| unique | about 627 ms | 75.83 MiB (94.64%) | 142 ns | 0.74–0.88 ms |

The overlay prototype kept a one-million-row blank skeleton and rendered 22
visible rows through one decoration provider:

| Workload | p50 | p95 | p99 | max | RSS growth |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1,600 sequential one-row scrolls | 0.077 ms | 0.088 ms | 0.094 ms | 0.272 ms | 20 KiB |
| 1,600 random forced redraws | 0.105 ms | 0.137 ms | 0.447 ms | 1.463 ms | 15.52 MiB |

The random run used an eight-page LRU and incurred 1,729 misses, 1,721
evictions, and 46.4 ms total restore time. `screenstring()` matched logical
text, backing rows remained blank, and no persistent extmarks accumulated.

These results justify a production spike. They do not replace end-to-end
benchmarks on the eventual CanvasDiff implementation.

## Production constraints

- Default page target: 256 rows with a 64 KiB uncompressed byte cap.
- Offset table: `u16` when safe, otherwise `u32`.
- Codec: checked raw storage everywhere; optional LZ4 through a narrow adapter
  when the runtime library is present.
- Cache: bounded LRU of restored pages, with visible and mutating pages pinned.
- Compaction: idle, generation-aware, at most one attempted page per tick.
- Provider: one provider per process, no persistent per-row extmarks, no
  mutation or scheduling from `on_range`.
- Every decoded page verifies codec tag, expected size, row offsets, and
  checksum before publication.
- Compression is accepted only when the complete cold representation is
  strictly smaller.

[ghostty-pr]: https://github.com/ghostty-org/ghostty/pull/13264
[pagelist]: https://github.com/ghostty-org/ghostty/blob/15484b607eb5a518dedf1548247c923b8abaae7c/src/terminal/PageList.zig#L46-L290
[pagelist-compression]: https://github.com/ghostty-org/ghostty/blob/15484b607eb5a518dedf1548247c923b8abaae7c/src/terminal/PageList.zig#L3968-L4312
[page-codec]: https://github.com/ghostty-org/ghostty/blob/15484b607eb5a518dedf1548247c923b8abaae7c/src/terminal/compress/Page.zig#L1-L175
[renderer]: https://github.com/ghostty-org/ghostty/blob/15484b607eb5a518dedf1548247c923b8abaae7c/src/renderer/Thread.zig#L758-L870
[memory]: https://github.com/ghostty-org/ghostty/blob/15484b607eb5a518dedf1548247c923b8abaae7c/src/terminal/mem.zig#L1-L174
[lz4]: https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
[demo]: https://www.youtube.com/watch?v=ZVAnhimPh8k
