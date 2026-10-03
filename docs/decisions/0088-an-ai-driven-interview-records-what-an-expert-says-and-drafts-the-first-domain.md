# An AI-driven interview records what an expert says and drafts the first domain

**Status:** Proposed; steps 2 and 3 are built. Date: 2026-10-03. The SME chapter and its `Interview` aggregate (decisions 1 to 4) exist at `lib/hecks/sme/`, and the generator and the record (decisions 7 to 9) exist as `Hecks::CLI::InterviewDraft`; specs run a whole interview without an AI and boot the domain it drafts. The AI loop and `hecks interview` itself (decisions 5, 6, 10 and 11) are still a proposal. It builds on [ADR 0087](0087-hecks-init-writes-the-stub-files-of-a-new-domain.md), the stub-writing `hecks init`, which asks nothing; this is the separate command for a guided start.

## Context

Real domains are not invented at a keyboard. They come out of conversations with someone who knows the business: what happens, in what order, who does it, and what must never happen. hecks has nowhere to keep that conversation, so a domain starts with no record of where its names and rules came from.

hecks has had a version of this. The Interview domain was deleted in commit `89d23dba` (2026-08-13) as a cleanup, with no design rationale in the message and nothing depending on it. It was four aggregates (`Interview`, `StandingQuestion`, `Finding`, `Proposal`) over a meta-domain session, with over 1,500 lines of Ruby that turned accepted proposals into bluebook source (`Session`, `Lowering`, `Source`, `Writer`, and a 698-line `bin/interview` with 18 subcommands). It depended on the old self-hosting layout, which may no longer exist. Its lessons were that provenance matters (every file carried a digest, and its writer reloaded its own output and compared it before writing), that a rule typed as prose cannot be turned into code (it rendered what it could not spell as unparseable on purpose), and that automatic merging into an existing bluebook is the hard part.

What exists today is a good base for a smaller version:

- An agent port declared as "the interviewer" (`lib/hecks/ports/agent.rb`), with `ask`, `interpret`, `critique` and `suggest_name`. Answers are validated into plain structs (a question with its reason, a proposal naming a verb with arguments and a rationale, a finding). Adapters keep no memory between calls; state is passed in.
- A `ClaudeCode` adapter (`lib/hecks/adapters/driven/claude_code.rb`) that runs the user's own `claude -p` as a subprocess, one call per turn, with tools switched off, a 120-second timeout and no credentials of its own.
- A scripted test double (`spec/fixtures/scripted_agent.rb`), so specs never call a model.
- An MCP door that lets an agent dispatch commands into a booted domain. It has no authentication (`role` and `actor_id` are self-asserted), and the README calls it the least battle-tested item on its list ([ADR 0062](0062-mcp-servers-need-real-authentication-before-any-network-transport.md) is still a draft).

## Decision

1. **Add an `SME` chapter holding an `Interview` aggregate, at `lib/hecks/sme/bluebook/sme.bluebook`.** It ships in the gem and is **not attached to the Hecks domain**: it is development-time work, so no `hecks` command boots it. `hecks interview` boots it on demand, on Memory, for the length of one session, as `hecks console subject=...` boots a domain today.
2. **An interview is one sitting.** Its lifecycle is `planned`, `underway`, then `concluded`, or `cancelled` from either of the first two. There is no pause: a second conversation is a second interview. It names the domain it is about with `subject`, a plain string spelled as the bluebook will spell it. Many interviews, with different experts on different days, feed one domain, and the domain is not an aggregate in SME (it would duplicate the bluebook).
3. **An interview holds exchanges and findings.**
   - An **exchange** is a question, the answer in the expert's own words, and an optional `topic` label.
   - A **finding** is an entity inside `Interview` with its own lifecycle (`proposed`, then `accepted` or `rejected`) and a number, and it cites the number of the exchange it rests on. There is one entity per kind, because each kind carries different fields: `ThingFinding` (a name, and the field that identifies one: an aggregate to be), `ActionFinding` (a name, the thing it happens to, the event it announces, and whether it creates the thing: a command to be) and `RuleFinding` (the expert's sentence, kept as text). Each has its own accept and reject commands (`AcceptThing`, `RejectRule` and so on), reached by the dotted verb `SME::Interview.ThingFinding.AcceptThing`, with the interview's reference and the finding's number.
   - The rule language cannot look inside a list, so two counts are held on the interview (`accepted_things`, `accepted_actions`), and a policy adds one when a thing or an action is accepted (`ThingAccepted` and `ActionAccepted` trigger `CountThing` and `CountAction`). `Conclude` reads the counts.
4. **Rules the domain enforces on the interview.** `Record` is refused unless the interview is underway. `Conclude` is refused unless at least one `thing` and one `action` are accepted; the developer ends the session with `done`, and the AI may suggest that it has enough. Live and after-the-fact interviews share this lifecycle: typing up notes later begins, records and concludes in one go.
5. **The AI interviews, hecks drives, and a person decides.**
   - hecks runs the loop and calls the existing agent port. The loop follows [ADR 0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md) section 11: a command records the request, a policy asks the port, and a command stores the answer.
   - The AI is the interviewer: it picks the next question, probes vague answers, and proposes findings. It never dispatches anything. hecks dispatches `Record`, `Propose` and the rest, so the domain's rules are the guard by construction.
   - A developer sits with the expert, relays each question, and types the answer back. The developer accepts or rejects each proposed finding; only accepted findings generate anything.
   - The adapter is the existing `ClaudeCode` one, so the work runs through the developer's own `claude` and hecks holds no model, no API key and no network call of its own.
6. **What the AI is shown each turn:** the subject, the exchanges so far, the accepted findings, and a computed list of gaps (a thing with no identifier, an action with no event). It is shown no files from the project.
7. **`hecks interview <Name>` is its own verb, and not a mode of `init`.** (The generator is built: `InterviewDraft.files` takes the interview as a plain hash, read from a booted record by `InterviewDraft.from_record`, and answers each file's path and text without writing any.) It shares `init`'s file-writing plumbing (the `.world`, the overlay, the `.gitignore`, and the check that nothing is replaced) but renders the bluebook itself, from accepted findings, where `init` writes a fixed stub. From accepted findings: a `thing` becomes an aggregate with its identity, an `action` becomes a command and its event (a creating command when the action says it creates, otherwise a command on an existing record, and a stub `Create` marked `TODO` when no accepted action creates), an accepted action whose thing was not accepted is kept as a comment and not lost, and a `rule` is written as a comment citing its source (`# RULE (INT-1 #4): a book can't be lent twice`) for a developer to turn into a `given`. Rules are never generated from prose.
8. **The first interview creates the domain; later ones never touch it.** `interview` never replaces anything. A later interview records its findings and writes its record with a proposed-additions section: the aggregates and commands it would add, in a fenced block, for a developer to merge by hand (`InterviewDraft.additions`). Automatic merging is left out because it risks overwriting hand edits.
9. **The record is a Markdown file per concluded interview,** at `<domain>/interviews/<reference>.md`, holding the exchanges and findings in order. A concluded interview does not change. SME itself stays on Memory; the file is the durable thing.
10. **Without the AI, and when a turn fails.**
    - `--no-ai` runs the same session with fixed prompts, and does so automatically when there is no `claude` binary.
    - Before the first turn, a one-time notice says the conversation is sent to a model through the developer's own login.
    - If a turn fails, `interview` says what failed, offers a plain prompt for that turn, and carries on. Everything recorded so far stays.
11. **No question bank in the first version.** The AI composes the questions, and a catalogue (the old `StandingQuestion`) is built when it is clear which questions recur.
12. **Tests.** A scripted agent plus a fixture transcript drive a whole interview in a spec, and a spec boots the domain that is generated from it. No spec calls a real model.
13. **Build order:** `init` ([ADR 0087](0087-hecks-init-writes-the-stub-files-of-a-new-domain.md)), then the SME chapter without the AI, then the generator, then the AI loop. The riskiest piece comes last, when the rest is proven.

## Consequences

- A domain can start from a conversation, and every name and rule in it traces to something an expert said.
- Nothing is added to the boot path: SME is shipped but loaded only by `hecks interview`.
- hecks takes no new dependency on a model. It depends on the developer's own `claude` being installed and logged in, or on running with `--no-ai`.
- Interview text can contain client details and is sent to a model. The notice says so; hecks stores no client names, so the Markdown record is the developer's to keep out of a public repository.
- One more aggregate to build, test and keep compatible with the generator.
- The old design's heaviest machinery (dispatching proposals into a meta-domain session) is not revived. Findings are plain data, and the generator is a function from accepted findings to bluebook text.

## Alternatives considered

- **Attach the SME chapter to the Hecks domain.** Rejected: every `hecks` command would boot a chapter that only one verb uses, and its generic command names would become top-level verbs.
- **Let the agent drive hecks through the MCP door.** It would work in the user's own session, but it needs an open session, and the door has no authentication.
- **A separate `Finding` aggregate.** Better once findings need correcting after the fact; it is another aggregate to run before there is a user. Entities inside `Interview` keep "can't conclude with nothing accepted" a single rule.
- **Pause and resume.** The old design had them. A second conversation as a new interview is simpler and matches many interviews feeding one domain.
- **Automatic merge into an existing bluebook.** The hardest part of the old system, with the most risk to hand edits.
- **Revive the old Interview as it was.** Over 1,500 lines against an architecture that has since changed; this version keeps its ideas and drops its machinery.
- **Make the interview a mode of `init`.** Rejected: `init` should stay a small, offline stub writer that asks nothing, and the interview needs a model, a conversation and a record.

## Open items

- The exact shape of the computed gap list, and how many gaps are shown per turn.
- How a `thing` finding with no identifier is handled when the developer tries to accept it: refused, or accepted with a placeholder identifier and a comment.
- Per-turn timeout and a ceiling on the number of turns (the adapter's default is 120 seconds a call).
- Whether `hecks interview` is in the gem's own command set (it needs the SME chapter, which ships in `lib/`, and a `claude` binary).
