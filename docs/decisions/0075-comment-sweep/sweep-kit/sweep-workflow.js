export const meta = {
  name: 'comment-sweep',
  description: 'Rewrite comments repo-wide to the ADR 0075 standard, one agent per batch, comment-only, self-checked',
  phases: [{ title: 'Sweep', detail: 'one agent per batch of files (322 batches)' }],
}

const T = '/Users/christopheryoung/.claude/jobs/cb15b686/tmp'
const BASE = '7cda564b82ca8d8d33dea8a0b36d84a325bbde95'
const CHECK = `ruby ${T}/comment_equiv.rb ${BASE}`

const RESULT = {
  type: 'object',
  properties: {
    batch: { type: 'number' },
    files: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          path: { type: 'string' },
          before: { type: 'number', description: 'comment lines before' },
          after: { type: 'number', description: 'comment lines after' },
          checker: { type: 'string', description: 'OK or the FAIL line from the checker' },
          note: { type: 'string', description: 'one short phrase only if something was hard or lost a real constraint, else empty' },
        },
        required: ['path', 'before', 'after', 'checker'],
      },
    },
  },
  required: ['batch', 'files'],
}

const RULES = `
STANDARD (ADR 0075 ticket 01). Voice: Rails API docs / Rack source; Rust reads like the standard library.
Delete first. Keep only what survives these rules.
ALLOWED: what a thing is (1 line); the contract (@param/@return/@raise, Rust # Errors/# Panics) on PUBLIC items only and only where the name and signature do not already say it; a short code example on a public entry point; a non-obvious WHY or constraint a future editor would break (one short line); a 1-2 line file/class/module header.
BANNED: design history ("used to", "no longer", "the old", "until now", "renamed", "legacy", "previously", "originally", "has since", PR/issue numbers, BUG#NN lead-ins); narration of the next line; inventories of what a module contains; essays; ALL-CAPS emphasis; section-divider banners; copies of other code inside comments. A real constraint survives as ONE line; the rest is deleted, never moved elsewhere.
LIMITS (hard): file/class/module header <= 2 lines of prose; method/item doc summary <= 2 lines plus tags where required; inline comment <= 3 lines; ANY contiguous comment block <= 12 lines including tags; every comment line < 100 characters. At most one bare ADR cite like (ADR 0053) per block; never invent one.
PUBLIC vs INTERNAL: a file's "publicNames" hint lists constants/types that the README, DSL reference, guides or docs/tools.md name. Those are public: give them a summary and a contract where needed. Everything else is INTERNAL: no doc block unless there is a real WHY (then one short line). Do NOT add :nodoc:, @api or #[doc(hidden)] tags. Specs: keep describe/it strings untouched; comments explain only why a test is shaped a certain way or what regression it pins. Bin scripts/CLI entry points: a 1-2 line header saying what the command does, plus usage only if non-obvious.
HARD CONSTRAINTS: change ONLY comment text. Every non-comment token must stay byte-for-byte identical. Never edit string literals, heredoc bodies, %q/%w blocks, or code. Keep magic comments and directives (frozen_string_literal, encoding, rubocop:, shebang, shellcheck, yamllint). Rust: never edit, move, add or remove a "// TMPL:" sentinel line, and do not touch ANY comment line between a "// TMPL:<id> BEGIN" and its "// TMPL:<id> END" (those are generator source). Rust: use plain // for inline, /// for a public item summary, //! for a 1-2 line module header. YAML/shell: only full-line # comments; never touch a # inside a run: | block or a heredoc. You may collapse blank lines left behind by deleted comments. If a file's comments are already within the standard, leave it alone (report before == after).
A pre-write hook may ask you to state importers/callers, affected API and the instruction; state them briefly ("comment-only edit, part of the repo-wide comment sweep the user directed") and retry.
Do not run tests, linters or formatters; do not commit; touch only the files in your batch.`

function prompt(id) {
  return `You are rewriting code comments as part of a repo-wide comment sweep in the git worktree /Users/christopheryoung/Projects/hecks/.claude/worktrees/comment-sweep-map (cwd is already there; stay there).

1. Read your batch spec: ${T}/batches/batch-${id}.json  (files, kinds, comment-line counts, publicNames hints, tmpl flag).
2. For each file, Read it and rewrite its comments under the standard below, using Edit (or Write for a full rewrite of the file if edits would be numerous — but only comment text may change).
3. Verify with exactly this command (it compares each file's non-comment tokens with the baseline commit): ${CHECK} @${T}/batches/batch-${id}.txt
   Every line must print OK. If a file prints FAIL, you changed code: undo it (the baseline copy is retrievable with the Bash command  git show ${BASE}:<path>  redirected to a temp file under ${T}/tmp_${id}/ , then re-apply only comment edits). Re-run until every file is OK. If you cannot get a file to OK after two attempts, restore it to the baseline content and report its FAIL line.
4. Return the structured result. Keep notes to one short phrase, only when something was hard or a real constraint could not be kept.
${RULES}`
}

phase('Sweep')
const ids = Array.from({ length: 322 }, (_, i) => i + 1)
let done = 0
const results = await pipeline(
  ids,
  (id) => agent(prompt(id), { label: `batch ${id}`, phase: 'Sweep', schema: RESULT }),
)
const ok = results.filter(Boolean)
log(`completed ${ok.length}/${ids.length} batches`)
const failed = ok.flatMap(r => r.files.filter(f => f.checker !== 'OK' && !String(f.checker).startsWith('OK ')).map(f => f.path))
const before = ok.reduce((n, r) => n + r.files.reduce((m, f) => m + f.before, 0), 0)
const after = ok.reduce((n, r) => n + r.files.reduce((m, f) => m + f.after, 0), 0)
const missing = ids.filter((id, i) => !results[i])
return { batches: ok.length, missingBatches: missing, files: ok.reduce((n, r) => n + r.files.length, 0), commentLinesBefore: before, commentLinesAfter: after, selfReportedFailures: failed, notes: ok.flatMap(r => r.files.filter(f => f.note).map(f => `${f.path}: ${f.note}`)) }
