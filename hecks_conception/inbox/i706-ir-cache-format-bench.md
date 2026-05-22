# i706 — IR cache format bench (load floor)

Benchmark of serialization formats for the cold-boot IR cache, measuring
DESERIALIZE (load) cost — the price paid on every cold start. Standalone
bench, release build, N=1000 deser iters after 100 warmup, mean+median.

Synthetic corpus matched to the real one (140 aggregates / 372 commands /
2783 attributes / 813 VOs in the actual tree). Bench used 162 aggregates
(cold-boot file count) at real per-aggregate densities: ~20 attrs, 3 cmds,
6 VOs, 0.2 queries each → 162 aggs / 486 cmds / 8100 attributes total.

## Results (rustc 1.94, --release, 3 runs, stable)

| format                    | size KB | median us | mean us | vs json |
|---------------------------|--------:|----------:|--------:|--------:|
| serde_json                |   928.1 |    ~1660  |  ~1670  |   1.0x  |
| bincode 1.3               |   574.2 |     ~640  |   ~639  |   2.6x  |
| rkyv 0.8 access (0-copy)  |   620.6 |     ~139  |   ~141  |  ~12x   |
| rkyv 0.8 deserialize(own) |   620.6 |     ~380  |   ~384  |   4.4x  |

Two rkyv numbers because they answer different questions:
- **access (zero-copy)**: validated pointer-cast into the byte buffer, no
  allocation. Only valid if the consumer reads through `ArchivedDomain`
  (borrowed, archived field types — `&ArchivedString`, not `String`).
- **deserialize (owned)**: rebuilds a real owned `Domain` (Strings/Vecs).
  This is the apples-to-apples row vs json/bincode, which always produce
  an owned `Domain`.

## Which row applies to the cache arc

The runtime (parser -> IR -> runtime/repository) executes against an
OWNED `Domain`. discover.rs / load_combined_domain hand owned IR around.
Unless the cache arc is rewritten to thread `ArchivedDomain` through the
runtime (large, invasive change), the relevant rkyv number is the
**owned-deserialize 380us**, not the 139us zero-copy.

## Integration cost

- **serde_json** — already a dep. `#[derive(Serialize, Deserialize)]` on
  the IR structs. Zero new crates. Largest payload (928 KB).
- **bincode 1.3** — reuses the SAME serde derives (drop-in once serde is
  on the IR). One small dep. Half the load time of json, smallest bytes.
  (Note: bincode 2.0 has its own Encode/Decode derives unless you opt
  into its serde feature — pin 1.3 to stay derive-free beyond serde.)
- **rkyv 0.8** — most invasive. Needs `#[derive(Archive, RkyvSerialize,
  RkyvDeserialize)]` on EVERY IR struct AND enum (MutationOp, ValueSpec,
  WhereOp, Direction, BlockParser). Pulls in rkyv + bytecheck + rancor +
  munge + ptr_meta + rend. Serialize needs an aligned buffer
  (`rkyv::to_bytes`), and the cache file must stay byte-aligned on read.
  The zero-copy WIN only materializes if downstream reads `ArchivedDomain`
  directly — taking the owned path throws most of rkyv's edge away
  (380us vs bincode 640us is a 1.7x gain for a much heavier integration).

## Recommendation

**Use bincode 1.3.** It is a true drop-in on top of the serde derives the
arc already plans for serde_json, halves load time (1660us -> 640us) AND
shrinks the payload (928 -> 574 KB), with essentially zero extra
integration cost over json.

**rkyv is NOT worth it for the owned-IR consumer.** Against owned
deserialize it is only ~1.7x faster than bincode (380 vs 640us) while
demanding archive derives on every struct+enum, an aligned-buffer
discipline, and six transitive crates. The dramatic 12x zero-copy win
(139us) requires the runtime to operate on `ArchivedDomain` end-to-end —
a big architectural change. Revisit rkyv ONLY if (a) load time becomes a
measured bottleneck after bincode, AND (b) the team is willing to thread
archived types through the runtime.

OPEN QUESTION for Chris: does the cache consumer need an owned `Domain`,
or could it be designed to read `ArchivedDomain`? If the latter is
feasible, rkyv's 139us zero-copy load (and skipping deserialize entirely)
changes the calculus. Default assumption here: owned -> bincode wins.

_Bench source: /tmp/cachebench (standalone, IR-shape copy with all three
derive sets; NOT merged). Worktree hecks-cachebench removed after run._
