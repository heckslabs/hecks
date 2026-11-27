# What a hecks release promises

**Status: planned for 7.0.0.** This page states the compatibility promise the command line and
the gem keep from 7.0.0, as [ADR 0163](decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md)
and [ADR 0164](decisions/0164-hecks-distills-to-a-core-that-no-satellite-is-needed-to-build.md)
decide it. Until 7.0.0 ships, the promise in force is the one in
[What a release number promises](1.0-readiness.md#what-a-release-number-promises).

The release number is the whole promise: a major may break, a minor may change behaviour and
says so, a patch does neither. This page says what "break" means for the command line, how
long an old name keeps working, and how a removal is announced.

## What counts as a breaking change

Any of these is a breaking change, and ships only in a major with a `Breaking:` entry in the
changelog:

- A command, query or argument removed or renamed, in the launcher, a generated project
  launcher or the MCP door.
- A command's arguments changed in shape: a required argument added, an argument's closed set
  of values narrowed, or a family of commands collapsed into one with an argument.
- An exit code changed, or a refusal code renamed or removed. The code is the contract; the
  wording beside it is not.
- A stored shape moved without a translation edge. A move with an edge is a migration the
  era machinery carries, not a break.
- A capability the runtime reaches a framework bluebook by, renamed or removed.

A module's name and which module an aggregate sits in are not part of the contract: a
command is called by its aggregate and verb, and a module only groups the listing.

## Exit statuses

A launcher exits with one of three statuses: `exe/hecks`, a project launcher `project_cli`
writes for a bluebook with a `launcher` setting, and the positional forms (`hecks run`,
`hecks docs` and the rest) alike. A script branches on the status; the text beside it is for a
person. A launcher of a bluebook with no `launcher` setting keeps the text every earlier
generator wrote, which exits 1 for every line it could not read as well; opting in gives it the
three.

| Status | Meaning | When |
|---|---|---|
| `0` | answered | a usage or a command's help; a command's outcome; a query's rows; a stream that ended; a port operation's refusal event, which is an answer |
| `1` | refused, or the run failed | the domain refused; a record is not there; a `--wait` run ended in a failure state, or a reaction of it was refused or crashed; a question reports a gap under `--wait`; the door refused the caller; the domain could not be opened; a crash |
| `2` | the line could not be read | no command named; a command or query the bluebook does not declare; a word the command does not take; a value its type cannot hold; a flag the command lacks |

A launcher's help ends with the same three in one line. The constants are
`Hecks::Adapters::Driving::ExitStatus`, which the runner and the positional table both return;
`spec/cli_exit_status_spec.rb` pins each situation.

## How long an old name lives

A rename is a breaking change, so it lands only in a major. From 8.0.0 the launcher keeps no
table of old names: the major that renames a command stops answering to the old one, and an old
spelling is refused like any name the bluebook does not declare, with `[unknown_command]` and
exit status 2. The refusal suggests the current names that share a prefix with what was typed.

7.0.0 kept an old name for one major: the launcher's `renamed` table and the former name an
aggregate's `formerly_known_as` gave both resolved it and printed the new spelling. 8.0.0
removes both, as [Renamed commands](#renamed-commands) lists. An aggregate's
`formerly_known_as` still names the table its rows were written under; only the command-name
resolution is gone.

A command named without its bang is refused with its bang spelling as the hint, and a name
without a bang reaches only a query.

A client project pins a hecks version, so a break reaches it when it moves to the major, not
when the major ships.

## How a removal is announced

Three places say that a name is going, and all three say the same thing:

- The changelog's `Unreleased` heading names the removal and the version it lands in, as
  soon as the change is on `main`.
- The migration guide for the major names each old spelling beside the new one.
- The usage record (`hecks usage`) counts the names callers type, so a caller of a name that
  is going shows up before the major ships.

## What this page does not cover

- The wording of a result, a refusal's text, or a progress line. The code and the exit
  status are stable; the words around them may change in any release.
- The layout of the help: the order of sections, the width of a column, which commands the
  `everyday` list names.
- The order in which a listing prints its entries.
- Output that is only for a person, such as colour. A pipe sees no colour at all.

## How a release happens

A release follows the lane rules in `CLAUDE.md`: a version bump lands on `main`, `stable` is
promoted onto it once every required check passed, and the release is cut from `stable`. A
bump ships only when the commit that set the version carries the owner's `Release-Approved-By`
line. Nothing here changes that; this page says what the number means once it is cut.

## Renamed commands

8.0.0 removes the launcher's `renamed` table from the Hecks world's `launcher` setting, and the
resolution of a command through its aggregate's former name. These spellings are unknown commands
from 8.0.0:

| Old spelling | Write instead |
|---|---|
| `push_train.push!` | `SendTrain.send!` |
| `pull_request.merge!` | `ReviewRequest.take!` |
| `<former_aggregate>.<verb>!`, for an aggregate with `formerly_known_as "<Former>"` | `<Aggregate>.<verb>!` |

A world whose `launcher` setting still lists `renamed:` has the key ignored.

## The query word

A query is written bare: `hecks Workspace.status`. `query` before a query's name is taken only
where a command of the same bluebook shares the name (`hecks quality_control query Ticket.filed`),
since the bare name reaches the command there. Before any other query the launcher refuses it with
exit status 2, naming the bare spelling. `ask` is not a query word from 8.0.0: `hecks ask …` is an
unknown command.
