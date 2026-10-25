# A bluebook is all of its files, and "chapter" is retired

**Status:** Proposed. Nothing is renamed yet. Date: 2026-10-25.

## Context

"Chapter" and "bluebook" both name the same thing, and neither is used consistently.

- A domain is declared by one or more `.bluebook` files. Each file's header (`Hecks.bluebook
  "Banking"` or `Domain: Banking`) names the domain, and every file with the same name adds to it.
  Banking is declared across many files, named by topic.
- The runtime already calls the whole a bluebook: the registry keys its entries by bluebook name,
  and its declarations hold `bluebooks` and `bluebook_sources`.
- The tooling calls the same whole a chapter: `--chapter Banking`, `Chapters.index`,
  `chapter_name`, `Examples for: <chapter>`, and ADR 0131's rule that "the `.bluebook` files of one
  chapter must all be the same form".
- "Chapter" suggests a part of something, so a reader takes it for a file. The code does not use
  it that way. An audit of every use in `lib`, `exe`, the Rust crates and the docs found no place
  where "chapter" means one file.
- A few places do treat a single file as the unit (see Consequences). They take the first file's
  header as the name, or match an examples file to a bluebook by file stem. These are shortcuts,
  not a concept.

The word costs authors and agents a step of translation, and it makes "a bluebook" ambiguous
between the file and the whole.

## Decision

1. **A bluebook is all of its files.** `Banking` is a bluebook. It has one name, one IR and one
   runtime, however many `.bluebook` files declare it. A file is a file, and has no name of its
   own beyond its path.
2. **"Chapter" is retired as a term for the whole.** New prose, errors, help and documentation say
   "bluebook". The file extension is unchanged.
3. **"Domain" is not the replacement.** ADRs 0080 and 0096 use "domain" for a hecksagon that
   attaches several bluebooks (the Hecks domain is several). Calling a bluebook a domain would
   erase that distinction.
4. **The sentence form's header stays `Domain: <name>`.** It is the word an author reads, and the
   parser already reads it as the bluebook's name. This ADR does not change it.
5. **A rule that names files says "files of a bluebook".** ADR 0131's "files of one chapter must
   all be the same form" becomes "the files of one bluebook must all be the same form". The rule is
   unchanged.
6. **Renames happen in three tiers, in this order.**
   - **Tier 1, words.** Comments, documentation, error messages, help text and local variable
     names. No behavior changes, and it can proceed file by file.
   - **Tier 2, interfaces, each with a deprecated alias.** `hecks-parse chapter` and `--chapter`
     become `bluebook` and `--bluebook`, and the `gem_chapters` JSON key gets a new name. The
     Composer HTTP key `chapter_name`, the `.world` launcher keys `chapters:` and
     `maintainer_chapters:`, the CMS editor JSON keys `chapter` and `chapters`, and the Ruby
     constants (`Hecks::Chapters`, `Hecks::Bluebook::Chapter`, `Registry#forget_chapter` and
     similar) each get a new name with the old one still accepted for at least one release. Every
     caller of the old name logs one deprecation line.
   - **Tier 3, the language's own names.** `ChapterName`, `ChapterNamespace`, the events
     `ChapterDeclared` and `ChapterAttached`, and the attributes `chapter` and `chapter_name` in
     the language bluebooks. These are part of the IR, event history and refusal strings, so each
     needs a translation edge between eras (see the Translation chapter's era-to-era rows) rather
     than an edit. This tier is **not decided here**; see Open questions.
7. **File-as-unit shortcuts are replaced, not renamed.** Each shortcut that takes the first file's
   header or matches by stem is changed to resolve the bluebook by name across all its files, or
   is documented as a deliberate single-file assumption.

## Consequences

- Authors, agents and documentation use one word for the whole. A reader never has to ask whether
  "chapter" is the file or the whole.
- The word "chapter" can later be reused for a real part of a bluebook if one is wanted, with no
  collision.
- Tier 2 touches several callers outside the gem: the Rust parser's CLI and its callers (the
  language server, the build tool and the editor extension), the CMS editor templates emitted into
  client projects, and consumers' `.world` and `.hecksagon` files. The alias period exists for
  them. Anything not yet read (see Open questions) must be checked before its tier starts.
- Tier 3 changes persisted names. Until it is decided, the language's own bluebooks keep saying
  "chapter" in event and attribute names while prose says "bluebook". That is a visible mismatch,
  and it should be recorded in the glossary rather than hidden.
- The single-file shortcuts become either name-based lookups or documented assumptions, which
  removes the cases where adding a second file to a bluebook changes its behavior.

## Open questions

- **Tier 3.** Does the language rename its own names (`ChapterName` and the rest), or keep them
  and let prose and identifiers differ? A rename needs translation edges for the language's own
  eras and a regeneration of the parser's tables and goldens. Keeping them is free but leaves the
  mismatch.
- **Serialization.** Whether `Attachment#chapter` or `Chapter::Provision` appear in any serialized
  form is not confirmed. If they do, they move up to tier 2.
- **Unread callers.** The editor extension and the build tool call `hecks-parse` by subcommand and
  flag. They were found by searching for the names, and not read.
- **A real part of a bluebook.** Banking's files are separate topics. If a named part is wanted
  later (a section of a large bluebook, addressable by name), is that a new concept with a new
  word, and does it justify keeping "chapter" for it?
- **Header redundancy.** Every file repeats the bluebook's header. Whether a file in a bluebook
  could omit it, because the folder or the project names the bluebook, is a separate question and
  is not decided here.

## Verification

When tier 1 is done, a search for "chapter" in prose finds only the tier 2 and tier 3 names and
the deprecation notes. For tier 2, each old name has a spec that calls it and expects the new
name's behavior plus one deprecation line. For tier 3, if taken, the era-translation checks
(`check_conformance` and the translation specs) pass for the language's own bluebooks.
