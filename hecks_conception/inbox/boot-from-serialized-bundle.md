# Boot the runtime from a serialized bundle (not a disk-walk)

**Posted:** 2026-06-22 (Chris's idea, mid storehouse-extraction). **Status:** noted for a future arc — NOT the current task. We finish the config-drive extraction first; this is the cleaner end-state it points at.

## The shape
Instead of the runtime *walking the disk* at boot to discover its corpus, boot it from a **serialized bundle** — all known bluebooks (domains, hecksagons, fixtures) parsed/resolved and handed in as one payload. The Runtime already takes exactly this shape internally: `boot_with_hecksagons(domain, …, hecksagons)` consumes a parsed `Domain` + `Vec<Hecksagon>`. So "load the corpus through serialization at boot" is just moving the parse/resolve step UPSTREAM of the runtime and feeding it the result. Not a new architecture — relocating an existing seam.

## Why it's the right decouple
- **It dissolves the disk-coupling we fought all session.** The entire `repo_root` / `HECKS_CONCEPTION_DIR` / `walk_up_from` saga exists ONLY because the runtime resolves its corpus by *finding files*. Hand it the corpus and that surface evaporates. The decouple stops being "teach the engine where the conception lives" and becomes "hand the engine the conception."
- **It's already the wasm story.** The embedded-bluebooks specializer does exactly this — bin-buddy's worker bakes its bluebooks in and boots `boot_with_hecksagons` from them. Bundle-boot generalizes that to the host runtime: corpus becomes a *payload*, not a filesystem walk. (bin-buddy is living proof of the source-bundle shape.)
- **Two boot paths, not a replacement.** dir-boot survives as the DEV path (edit a bluebook, reboot, no rebundle step). bundle-boot is the DEPLOY/wasm/published path. The config-driving done in the extraction (repo_root env, etc.) still serves dir-boot AND the bundler (which finds the conception once to read it). Nothing already committed is wasted.

## The deepest win: the bundler is where the GATES live
The bundle is built by a trusted step (`storehouse bundle` / the specializer) where the macrophage, validators, parity, and — the one to flag — **FQN-strict resolution** all run BEFORE serialization. The runtime receives an already-validated, already-resolved, **fully-qualified** artifact. Specifically: the bundler resolves every ref to canonical FQN and SEALS it, so the runtime never sees an ambiguous 2-seg ref. The "flip" deferred on 2026-06-22 stops being a risky global runtime change and becomes a bundling pass — ambiguity can't reach the runtime because the bundle already resolved it. The bundle is a sealed, validated, fully-qualified artifact. Stronger than "validate at the door."

## The adapter benefit survives in static form
All known hecksagons being in the bundle means every declared Family/Driver edge is known at boot — the discovery projection (what each out-of-process adapter host subscribes to) is fully populated from the serialized set. Adapters still attach out-of-process and re-enter through storehouse ; they just bind against a runtime whose hexagon wiring was fixed at boot rather than streamed. Keep the out-of-process adapter model ; drop the dynamic-merge idempotence headache.

## The one real design question: source vs IR
- **Source-bundle FIRST** — concatenated `.bluebook`/`.hecksagon` text, parse on boot. Removes the disk-walk already (one payload, not a tree), reuses `parser::parse` unchanged, zero serde surface, human-auditable. De-risks the bundle-boot PATH without betting on IR stability. Cost: the ~7s parse stays at boot.
- **IR-bundle as the END-STATE** — serialized `Domain`/`Hecksagon` structs. Skips parse, IS the IR-cache perf floor (groomed #20), makes host/wasm/published uniform. Honest risk: **version-coupling** — the IR struct changes constantly in active dev, so a serialized IR bundle goes stale the moment the engine moves. Fine when the SAME engine version builds + boots it (automatic for wasm/embedded ; for `storehouse bundle && storehouse run` with one binary). Fragile only when a bundle ships to a different engine version — needs versioned serde + a rebundle-on-mismatch fallback.

**Recommendation:** source-bundle proves the path and unblocks the decouple ; IR-bundle is the perf/uniformity end-state once the path is real and the IR serde is versioned.

## Related: the test `include_str!` couplings
~21 `include_str!("../../hecks_conception/….hecksagon")` consts across ~9 test files (expiry_sweep, seam1, liveness_sweep, dep_count, …) are COMPILE-TIME conception embeds — they bake conception files into the test binary and won't compile standalone. Under bundle-boot these stop being a problem (a test bundle / fixture replaces them) instead of needing per-file surgery. Track them with this arc, not the config-drive sweep.

## Next step when this arc opens
Design `storehouse bundle` properly: the command, the artifact format (source-first), where it slots into the existing commit-time gates, and how `serve` / CLI / wasm each consume it. It folds the storehouse extraction AND the FQN-flip into one cleaner shape. Write it up before code.
