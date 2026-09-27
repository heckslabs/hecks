export const meta = {
  name: 'comment-sweep-pass2',
  description: 'Second pass: tighten remaining over-limit comment blocks, long lines and history phrases',
  phases: [{ title: 'Tighten', detail: 'one agent per batch of offending files (30 batches)' }],
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
          fixed: { type: 'string', description: 'what you tightened, a few words' },
          leftover: { type: 'string', description: 'violations you deliberately left (heredoc/string text, load-bearing) or empty' },
          checker: { type: 'string', description: 'OK or the FAIL line' },
        },
        required: ['path', 'checker'],
      },
    },
  },
  required: ['batch', 'files'],
}

const RULES = `
STANDARD (ADR 0075). Rails-API-doc voice. A comment states what a thing is (1 line), the contract on PUBLIC items only where name+signature don't already say it, or a non-obvious WHY as one short line.
LIMITS (hard): header <= 2 lines of prose; item doc summary <= 2 lines plus tags; inline comment <= 3 lines; ANY contiguous comment block <= 12 lines including tags; every comment line < 100 characters. At most one bare ADR cite per block.
BANNED: design history ("used to", "no longer", "the old", "until now", "renamed", "legacy", "previously", "originally", "has since", PR/issue numbers, BUG#NN lead-ins), narration, inventories, essays, ALL-CAPS emphasis, dividers, copies of other code. Delete first; a real constraint survives as ONE line; never move rationale elsewhere.
THIS IS A SECOND PASS: a first pass already rewrote these files but left some violations. Find what is still over the limits: (a) comment blocks longer than 12 lines, (b) comment lines of 100+ characters (rewrap or shorten), (c) history phrases. Fix only those. Do not re-litigate comments that already meet the standard.
SKIP: comment-looking lines inside heredoc bodies, string literals, %q/%w blocks, or text after __END__ are DATA (generated YAML/Makefile/Dockerfile/CloudFormation text etc.); leave them and report them under leftover. Keep magic comments and directives (frozen_string_literal:, encoding:, rubocop:, shebang). Rust: never edit, move, add or remove a "// TMPL:" sentinel line, and do not touch comment lines between a TMPL BEGIN and its END. Rust module header uses //!, item summary ///, inline //. Do NOT add code fences (\`\`\`) to Rust doc comments. Do NOT add :nodoc:, @api or #[doc(hidden)] tags. YAML/shell: only full-line # comments.
HARD CONSTRAINTS: change ONLY comment text; every non-comment token must stay byte-for-byte identical. Do not run tests/linters/formatters; do not commit; touch only your batch's files.
A pre-write hook may ask you to state importers/callers, affected API and the instruction; state them briefly ("comment-only edit, part of the repo-wide comment sweep the user directed") and retry.`

function prompt(id) {
  return `You are tightening code comments in a repo-wide comment sweep, in the git worktree /Users/christopheryoung/Projects/hecks/.claude/worktrees/comment-sweep-map (cwd is already there; stay there).

1. Your files are listed in ${T}/batches2/batch-${id}.txt (one path per line). Read each and fix its remaining violations under the standard below, using Edit.
2. Verify with exactly: ${CHECK} @${T}/batches2/batch-${id}.txt
   Every line must print OK. On FAIL you changed code: undo it (retrieve the baseline with a Bash command that writes  git show ${BASE}:<path>  to a temp file under ${T}/tmp2_${id}/ , compare, and re-apply only comment edits). If a file still fails after two attempts, restore its pre-edit content and report the FAIL line.
3. Return the structured result.
${RULES}`
}

phase('Tighten')
const ids = Array.from({ length: 30 }, (_, i) => i + 1)
const results = await pipeline(ids, (id) => agent(prompt(id), { label: `pass2 batch ${id}`, phase: 'Tighten', schema: RESULT }))
const ok = results.filter(Boolean)
const failed = ok.flatMap(r => r.files.filter(f => !String(f.checker).startsWith('OK')).map(f => `${f.path}: ${f.checker}`))
log(`completed ${ok.length}/${ids.length} batches; ${failed.length} self-reported failures`)
return { batches: ok.length, missing: ids.filter((id, i) => !results[i]), failed, leftovers: ok.flatMap(r => r.files.filter(f => f.leftover).map(f => `${f.path}: ${f.leftover}`)) }
