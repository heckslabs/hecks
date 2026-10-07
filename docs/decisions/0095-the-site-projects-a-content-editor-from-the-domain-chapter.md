# The Site projects a content editor from the domain chapter

**Status:** Proposed. Date: 2026-10-06. A project that publishes content needs its editors to create and change it. The Site chapter projects a third-party content system's half of the sign-in and drives the domain from it; this adds a small editor of our own, generated from the domain's bluebook, so editing needs no third-party CMS.

## Context

`AdminCms` and `PayloadDriver` assume a content system that owns the editing screens and the data model, and the domain is made to follow it. The domain is already declared: its aggregates, attributes, value objects, lifecycles, commands (with roles) and queries say what can be created and what can be changed, and the host already answers `/dispatch` for exactly those. An editor is the part that is left, and it can be derived.

ADR 0092, ADR 0093 and ADR 0094 were taken when this was merged, so this is 0095.

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
- An attribute whose value object is a structured document body is edited with a rich-text widget (see the addendum).
- `rust/host` is unchanged.

## Alternatives considered

- **One generated page set per aggregate.** More output, and a change to the shape of any page means a change to every one; the generic server has one set of pages.
- **A browser app calling the host.** The host refuses a non-loopback caller by design, and a browser that could reach it would hold the domain's whole write surface.
- **Keeping editor state in the domain.** The domain would then name its editor; the editor is a client of the domain, like the site.

## Open items

- Nothing yet runs the editor against a live host; the pages are run under node against a stand-in host in the specs.
- A command that acts on another aggregate's instance is offered with a field for its id rather than a picker.
- Entities inside an aggregate, and closed-set (`admits`) attributes as choice lists, are not given their own inputs yet.

## Addendum: the rich-text widget

This follows the decision above and does not depart from it, so it is an addendum and not a new ADR.

- **The widget is chosen by shape.** An attribute gets `widget: "body"` when its value object has a `blocks` list of a value object that has `kind` and `spans`; neither the attribute's nor the value object's name matters.
- **The domain's tree is the only format.** The widget edits the domain's own `blocks` (each with `kind`, `level`, `align`, `indent`, `spans`, `items`, `media_ref`, `alt`, `caption`; spans with `text`, `marks` and `href`; a line break is a span of `"\n"`; a nested list is flat items with a `depth`). It posts that tree as the dotted-path fields every other value object and list uses (`body.blocks.0.spans.1.marks.0.name`), read back by `src/ui/input.ts`. There is no JSON of an editor format and no second encoding. The server renders the current value as hidden inputs, so a browser without the script posts the body unchanged.
- **Plain JavaScript, no DOM in the pure part.** `body_model.js` (`bodyToHtml`, `emptyBody`, `bodyToFields`, `safeHref`) and `body_parse.js` (`htmlToBody`, `htmlToBodyWithNotes`, a small tokenizer and tree with no DOM) run in node and in the browser; `body_widget.js` is the browser part. They are `.js`, not `.ts`, because the package runs under node's type stripping with no build step and a browser cannot load TypeScript; `tsconfig.json` gains `allowJs` so the TypeScript pages can import them. The server serves the three files to a signed-in editor at `<base_path>/assets/<name>`. No npm runtime dependency is added.
- **Escaped always.** Every text, attribute value and address is escaped on its way into markup; an address is kept only when it is a path (not `//`), `http://`, `https://`, `mailto:` or `tel:`, with no whitespace or control characters; marks, kinds and alignments outside the closed sets are not written. The list and detail pages render the body read-only with `bodyToHtml`.
- **Reduced, never silently dropped.** HTML pasted or dropped into the widget is reduced to the nearest block or mark by `htmlToBodyWithNotes`, and the widget shows what it reduced (a heading below level 4, a table, a script, an image with no media key, a link to a disallowed address, inline styles other than weight, italic, underline, strike-through and alignment). The result is normalised: adjacent spans with the same marks and address are merged and empty ones dropped, so a body with such spans reads back merged.
- **Not yet verified:** the widget was driven in Chrome against a static page, not against a live host, and its browser behaviour (execCommand-based marks, prompts for links and images) is not under the specs, which run the pure functions and the server pages under node.
