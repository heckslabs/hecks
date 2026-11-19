# Names are plain words, rail machinery and characters, under Hecks on Rails

**Status:** Proposed. Date: 2026-11-19. Asked by the owner on 2026-11-19 (about 10:00) to record the
naming discussion of that morning. The owner locks this record before any rename starts: names are
decided before they are built. Nothing here is renamed yet. Builds on
[0205](0205-the-pipeline-is-its-own-project-switchyard-on-a-pinned-hecks.md), which names the
pipeline project Switchyard, and on [0222](0222-signalbox-runs-on-five-laws.md), which builds
Signalbox and Roundhouse under these proposed names.

## Context

Hecks has grown names from three sources at once, and they do not read as one family.

- **What people write** carries coined words. A domain's wiring is a hecksagon, its settings are a
  world, and its Given/When/Then cases are behaviors. A newcomer has to learn each coinage before
  reading a file. Bluebook is the exception that has earned its place.
- **The machinery** that moves work (landing, the push train, the fill, the cap, sessions) has
  names from several pictures: trains and a merge queue, a delegate, a heartbeat, a ticker, an
  idler. Most of it sits in one bluebook, the Delegate bluebook, which holds 19 aggregates in 3,483
  lines (counted 2026-11-19 by its `aggregate` declarations and `wc -l`). Because so many concerns
  share that one file, it is where most of the landing clashes of the night of 2026-11-18 happened.
- **The parties you talk to** already have names: Miette, and the interview product, Discovery.

ADR 0205 (Proposed) uses Switchyard for the pipeline as its own project. This record uses
Switchyard for the delivery context inside that pipeline. The two agree: delivery is the part of
the pipeline that 0205's project is named after. If 0205 is accepted, the project and its delivery
context share the name, and the delivery context is the narrower sense.

## Decision

1. **There are three kinds of name.**
   - **Plain words** for what people write and read.
   - **One metaphor family, rail,** for the machinery.
   - **Characters** for the parties you talk to.

2. **What people write gets plain words.**

   | Today      | Name      | What it is                                    |
   |------------|-----------|-----------------------------------------------|
   | Bluebook   | Bluebook  | the domain, declared (kept)                   |
   | hecksagon  | Wiring    | the ports and adapters a domain plugs into    |
   | world      | Settings  | the values a domain runs with                 |
   | behaviors  | Examples  | Given/When/Then cases                         |
   | work items | work items | kept                                       |
   | epics      | epics     | kept                                          |
   | decisions  | decisions | kept                                          |

   Whether the file extensions change with the words is left open (Open items, 1).

3. **The machinery is rail, because work moves in discrete batches.** A commit waits, is coupled
   into a train, is switched and is signalled through. Rail has a name for each of those steps.

   | Name       | What it holds                                                       |
   |------------|---------------------------------------------------------------------|
   | Switchyard | delivery: landing, gates, trains, the merge queue, releases (kept)  |
   | Signalbox  | allocation, load and protection: the fill, the cap, shedding, budgets |
   | Roundhouse | sessions and runs                                                   |
   | Timetable  | planning, ranking, the daily cycle                                  |
   | Logbook    | the ledger and the metrics                                          |
   | trains     | kept                                                                |

   Switchyard belongs to both rail and power, which suits it (decision 6). Signalbox exists to turn
   compute into landings as efficiently as it can without starving the person using the machine.
   It directs Roundhouse, which runs the sessions.

4. **Delegate gives way to Signalbox and Roundhouse.** Which of Delegate's 19 aggregates goes where,
   and which are deleted, is decided by
   [0222](0222-signalbox-runs-on-five-laws.md), whose table gives each one a home. This record names
   the two contexts and does not place aggregates. Under 0222, MergeWindow becomes Signalbox's
   `Response` rather than a Switchyard part: gates wait their turn under pressure, which is load.

5. **The parties you talk to are characters.** Miette is kept. Discovery, the interview product,
   is kept and stays a plain word.

6. **The brand.** Hecks stays the name of the language and the compiler. The working name of the
   platform around it is **Hecks on Rails**. The owner chose it because it fits the rail metaphor,
   and because it is a cheeky answer to "why write a DDD framework when we have Rails?".

7. **The grid explains load and protection, and names nothing.** Running the pipeline is like
   running a power grid. Compute (CPU time, memory and the model usage budget) is the supply.
   Sessions are load. The cap and the boot budget are breakers. Each pipeline is a microgrid, and
   Hecks is the virtual power plant that coordinates many of them. The picture is used to explain
   Signalbox's work. The product names stay rail.

8. **"Negawatts" names the compute a change gives back.** It is Amory Lovins's word from the
   mid-1980s for energy saved rather than generated. Hecks uses it as a word for compute reclaimed,
   not as a brand.

## Consequences

- **The Rails integration is renamed first.** A repository named `hecks_on_rails` holds the Rails
  integration today. It sits outside this tree, beside it in the owner's projects, so this record
  cannot check it. It is renamed (for example to hecks-rails) before Hecks on Rails is used as the
  platform name, so that the two never collide. Locking this record does not wait for that rename.
- **The trademark question comes before anything public.** "on Rails" is checked as a mark before
  Hecks on Rails appears on a site, in a pitch or in a package name.
- **Every rename lands in one coordinated wave.** Code, bluebooks, docs, the launcher's command
  names and the agent prompts change together, with a check that fails on any leftover old name.
  A half-renamed tree is worse than either name.
- **Splitting Delegate also helps landing.** With Signalbox and Roundhouse in separate files, a
  change to the cap no longer clashes with a change to session cleanup. 0222 does the split;
  this record only names its parts.

## Open items

1. **File extensions.** Do `.hecksagon`, `.world` and `.behaviors` become `.wiring`, `.settings`
   and `.examples` in the same wave? This touches the Ruby and Rust parsers, the generators and the
   corpus. It could be its own later record, with this one locking the words only.
2. **The leftover-name check.** Its design (a spec, a gate stage, or both) is a follow-up work item,
   filed when the owner locks this record.
3. **The Rails integration's new name.** hecks-rails is a suggestion.
4. **The trademark check.** Who runs it, and before which first public use.
