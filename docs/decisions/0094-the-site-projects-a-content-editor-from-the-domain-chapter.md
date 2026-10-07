# The Site projects a content editor from the domain chapter

**Status:** Proposed. Date: 2026-10-06. A project that publishes content needs its editors to create and change it. The Site chapter projects a third-party content system's half of the sign-in and drives the domain from it; this adds a small editor of our own, generated from the domain's bluebook, so editing needs no third-party CMS.

## Context

`AdminCms` and `PayloadDriver` assume a content system that owns the editing screens and the data model, and the domain is made to follow it. The domain is already declared: its aggregates, attributes, value objects, lifecycles, commands (with roles) and queries say what can be created and what can be changed, and the host already answers `/dispatch` for exactly those. An editor is the part that is left, and it can be derived.

ADR 0092 and ADR 0093 were taken when this was written, so this is 0094.

## Decision

1. **A projector, `:site_cms_editor` (`Site::CmsEditor`), emits the files of a small Node/TypeScript package.** It takes the `Editor` row (the domain's directory and chapter, where the editor is served, the session cookie, the host's address variable, the login page, the roles) and the domain chapter, and writes under `--editor=<dir>`: `src/schema.ts`, the server, the sign-in, the pages, the form reader. The output is a pure function of the row and the chapter, with the banner every projection has and no time or machine in it, so it is golden-tested and `--check` holds it current.
2. **The editor is generic by aggregate.** The pages and forms are not generated per aggregate. `src/schema.ts` carries the chapter's shape as one typed constant (names, kinds, optional, `list_of`, value objects, lifecycle transitions, command roles, queries), and the same few files read it for every aggregate. A value-object attribute is a nested fieldset, a `list_of` attribute is a run of repeatable rows, a lifecycle state is a badge, never an input, and a lifecycle move is offered only from the states it applies in. This is the shape the CMS packages use (a slug as identity, value objects, lists nested two levels, optional parts, a lifecycle, commands that act on one instance); an aggregate of any other shape is edited by the same code.
3. **The domain never holds editor JSON.** The editor reads and dispatches through the host like any other client (`@hecks/client`'s `HostClient`: `read`, `query`, `dispatch`), and nothing about the editor is declared in the domain: no editor attribute, no editor aggregate. The editor-facing detail (title, base path, roles) is in the `Editor` row beside the route table, on the Site side, as `PayloadField` rows are.
4. **The server is a sidecar and authenticates for itself.** The host honours `/dispatch` only from the same machine, so the editor is a server-side caller, not code in the browser, and the browser never gets that access. Every person is authenticated by the editor: the site's admin hand-off sends a signed-in admin to `sso_path` with a short-lived account token, which the server verifies with the secret it shares with the host (`verifyAccountToken`); the editor then asks the host's members list whether the person holds one of the roles, and only then starts its own signed session cookie. The list is asked again on every request (remembered for a minute), so removing someone locks them out; a question that cannot be asked is a no. Posts from another site are refused (SameSite=Lax and an Origin check). This is the sign-in `AdminCms` generates for a content system, written for a plain server.
5. **A command's outcome is judged by the state that comes back.** The host answers HTTP 200 whether or not the domain refused, and its `refusals` can be replayed from history. The editor reads the instance before and after; a lifecycle move must reach its target, any other command's arguments must be in the new state, and only when nothing changed does the last refusal naming this verb decide. A refusal is shown inline on the form in the domain's own words, with the person's input kept. Commands run as the role they declare.
6. **`@hecks/client` gains `query(name, args?)`** (and `rowsOf` to read its answer), because the host's `/dispatch` already answers `{"query": name, "args": {...}}` and a list page is a query. It is additive.
7. **Templates are files, not heredocs.** The TypeScript is about nine hundred lines; each file is a `.tmpl` with `__NAME__` placeholders beside the projector (as the deploy projections keep theirs), so it reads, highlights and type-checks as TypeScript. Placeholders are filled in one pass, so a value that looks like one is left as it is.

## Consequences

- A project gets an editor for its domain from a row, with no content system to run, secure and keep in step with the domain.
- Adding an attribute, a command or a lifecycle state to the bluebook changes the editor on the next projection; a stale editor fails `--check`.
- The `Body` value object is shown as a read-only outline and carried through a form unchanged. Its editor widget is the next slice.
- `rust/host` is unchanged.

## Alternatives considered

- **One generated page set per aggregate.** More output, and a change to the shape of any page means a change to every one; the generic server has one set of pages.
- **A browser app calling the host.** The host refuses a non-loopback caller by design, and a browser that could reach it would hold the domain's whole write surface.
- **Keeping editor state in the domain.** The domain would then name its editor; the editor is a client of the domain, like the site.

## Open items

- The rich-text widget for `Body` attributes (slice 2).
- Nothing yet runs the editor against a live host; the pages are run under node against a stand-in host in the specs.
- A command that acts on another aggregate's instance is offered with a field for its id rather than a picker.
- Entities inside an aggregate, and closed-set (`admits`) attributes as choice lists, are not given their own inputs yet.
