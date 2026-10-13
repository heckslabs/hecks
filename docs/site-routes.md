# Site routes: one route table, one `routes.ts`

A website decides which pages exist in many places: the middleware that hides a switched-off page, the
navigation, the footer, the sitemap, the robots file, the CMS that previews a page. The Site chapter holds
that decision once, as a table the project declares, and projects it into a single TypeScript module every
one of those places imports.

## Declaring the table

A project writes its routes as `member` rows of a `value_object "Route"` in one of its own chapters, and
its hecksagon attaches the Site chapter:

```ruby
Hecks.bluebook "StudioSite" do
  aggregate "SiteMap" do
    # ... an identity, as any aggregate has one ...
    value_object "Route" do
      attribute :path, String
      # ... one attribute per field the rows use ...
      member path: "/about", label: "About", source: "global:about", nav_order: 2, mobile_order: 2
      member path: "/blog/:slug.html", source: "collection:posts", preview: "draft"
      member path: "/podcast", switch: "podcast", off: true
      member source: "command:Studio.Inquiry.Submit"
    end
  end
end
```

```ruby
Hecks.hecksagon "StudioSite" do
  attaches "Site"
end

# Where Site's own aggregates are kept, as for every chapter a project attaches.
Hecks.hecksagon "Site" do
  persisted_by "Memory"
end
```

The rows are plain data, not commands: a route table is not an event history, and a row that reads wrongly is
fixed by editing the line. The fields a row may carry, and the closed sets their values come from, are the
`Route` aggregate of the Site chapter (`lib/hecks/site/bluebook/site.bluebook`); the sets are in no other
place.

| field | meaning |
|---|---|
| `path` | `/blog/:slug.html` names a parameter, a trailing `/*` a prefix. Left out when `source` is a command or query. |
| `kind` | `page` (default), `endpoint`, `redirect`, `rewrite` or `proxy`. |
| `render`, `auth`, `origin`, `preview` | closed sets: `prerender` or `ssr`; `public`, `admin` or `signed`; `website`, `cms`, `domain` or `assets`; `public` or `draft`. |
| `cache` | `page`, `home`, `static`, `media`, `immutable` or `no_store`. Defaults to `no_store` for an admin or signed route and an endpoint, `immutable` from `assets`, `page` otherwise. |
| `methods` | the verbs the route answers, comma separated, `GET` by default, `POST` for a command. |
| `edge_methods` | the verbs the edge lets through for the route, when more than `methods` (below). Defaults to `methods`. |
| `source` | `none`, `global:<slug>`, `collection:<name>`, `command:<Chapter>.<Aggregate>.<Command>` or `query:...`. |
| `indexable` | whether the sitemap lists it; true for a public page that is on. |
| `switch`, `off` | the id a page is switched by, and whether it is off now. An off page answers 404 and stays out of the sitemap; it may keep its navigation slots (below). |
| `compress`, `alb_rule`, `cdn` | for the edge, below: whether CloudFront compresses the response (true by default); the listener rule that carries the path; false for a path the CDN never sees. |
| `label`, `seo`, `seo_title` | the text a navigation shows, an id for the page's search metadata, and the title search engines show for it. |
| `redirect_to`, `aliases` | the target of a redirect or rewrite, and extra paths that redirect to a page. |
| `nav_group`, `nav_order`, `mobile_order`, `mobile_heading`, `footer_column`, `footer_order`, `admin_key`, `admin_order` | where the page sits in the desktop, mobile, footer and admin navigation, and the heading that opens a section of the mobile menu. |

### Navigation

A row sits in a menu with `nav_order` (desktop), `mobile_order`, `footer_column` or `admin_key`, and needs a `label`. What it may be:

- **Any route that answers GET**, whatever its kind: a page, an endpoint, a redirect, a rewrite or a proxy. An admin link to an
  endpoint that redirects is a row of that endpoint with an `admin_key`. A route that answers only POST, or has a parameter, is refused.
- **An off page keeps its slots.** The page stays in the arrays; its entry carries `switch: "<id>"` and `on: false`, and the site drops
  an entry whose `pageIsOn(entry.switch)` is false. Switching the page on is `off: false` and a regeneration, and the slots are
  already there. An entry of a page that is on carries neither key, so a table with no off page in a menu generates what it did before.
- **A heading in the mobile menu** is `mobile_heading: "Experiences"` on the first row of a section; its entry in `NAV_MOBILE`
  carries `heading: "Experiences"` and the site draws the heading above it. The list stays flat, in `mobile_order`.
- **A link to a fragment, or a second link to a page**, is a `member` row of a `value_object "NavLink"` of the same chapter. A route
  sits in each menu once, and one path is declared once, so a second link to `/about` is not a second route: it is a `NavLink` with
  the `path` of a route that answers GET, an optional `fragment` (an element id, without `#`), a `label`, and the same slot fields
  as a route (`nav_group`, `nav_order`, `mobile_order`, `mobile_heading`, `footer_column`, `footer_order`, `admin_key`,
  `admin_order`). Its entry carries `fragment: "opening-hours"`; the site links to `path + "#" + fragment`. It is off with the route it
  points at, and is refused when the route is not declared, has no slot or label, or is an admin page in a public menu.

```ruby
value_object "NavLink" do
  attribute :path, String
  attribute :fragment, String
  attribute :label, String
  attribute :footer_column, String
  member path: "/about", fragment: "opening-hours", label: "Opening hours", footer_column: "Gallery"
end
```

### Search metadata

`seo` is an id and `seo_title` the title for it. A row that sets `seo_title` has `seoTitle` in its `ROUTES` entry, after
`redirectTo`; a row that does not has no such key, so a consumer reads it with `"seoTitle" in route`.

### Matching paths in the module

`matchesPath(pattern, pathname)` reads a path pattern as the CDN does: `:name` is one segment, and `*` is any run of characters,
`/` included, wherever it stands. `/pay/*` matches `/pay/7` and `/pay/7/receipt` but not `/pay`; `/admin*` matches `/admin`,
`/admin-inbox` and `/admin/members`. The rule applies to the off paths, `NOT_FOR_SEARCH` and any pattern a consumer passes. A
pathname is compared without `.html` and without a trailing slash.

### A public page beneath a prefix that is not

A sign-in page is public and sits under `/admin*`. A route's cache class comes from its auth (`no_store` for admin and signed,
`page` for public), and a public row under a prefix that is admin or signed would get `page` from that rule, so such a row has to
name its cache class: `member path: "/admin-login", render: "ssr", cache: "no_store", edge_methods: "GET,POST", indexable: false`.
Without `cache` the table is refused, naming the prefix. `indexable: false` keeps it out of the sitemap, which a public page is in
by default. With the same edge verbs and cache class as the prefix the row rides the prefix's behaviour and makes none of its own.

`hecks site site_projection.project_site <project>` refuses a table that contradicts itself and names every problem at once.

## Admin sign-in: `admin.ts`

A project that serves admin pages from a domain host declares one `member` row of a `value_object "Admin"` in the chapter that
holds its route table, and the tool writes `admin.ts` (or `admin.mts`, as `extension` says) beside `routes.ts`. A project with no
`Admin` row gets no `admin.ts`, and the other output is unchanged.

| field | meaning | default |
|---|---|---|
| `session_cookie` | the name of the session cookie the host sets | required |
| `host_env` | the environment variable that holds the host's address | required |
| `login` | the path of the login page; a public row of the table | required |
| `sso` | the path of the hand-off to the content system; an `admin` endpoint row | required |
| `host_default` | the host's address when the variable is unset | `http://127.0.0.1:4322` |
| `roles` | the roles that count as an admin, comma-separated | `Admin,Owner` |
| `session_max_age` | the cookie's lifetime in seconds | `1209600` (14 days) |
| `account_path`, `members_path`, `sso_token_path` | the host's routes for who is signed in, the membership list, and a hand-off token | `/accounts/me`, `/members`, `/accounts/sso-token` |
| `sso_target` | the content system's own sign-in endpoint | `/cms/api/sso` |
| `verdict_ttl_ms`, `timeout_ms` | how long a verdict on one session is reused, and how long to wait for the host | `10000`, `5000` |
| `cms_base` | the path the content system is served under; `sso_target` must be under `<cms_base>/api/` | `/cms` |

The module exports `ADMIN` (the settings), `adminGate(pathname, cookie)`, `currentAdminSession`, `currentAdminEmail`,
`currentAccountEmail`, `ssoRedirect(cookie, to)`, `isActiveAdmin`, `forgetAdminSessions` and `configureAdmin({ host, fetch })`. It
imports `routes` beside it and nothing else.

`adminGate` decides from the table: the most specific route that matches the path wins (the characters outside its wildcards
count, so `/admin-login` outranks `/admin*`), and an `admin` route needs a signed-in person whom the host's membership list holds
with one of the roles and not disabled. A request without one is sent to `login`; a path under the draft-preview prefix is
refused with `{ allow: false, status: 401 }` instead. A verdict on one cookie is remembered for `verdict_ttl_ms`, and
`forgetAdminSessions()` drops them, for after a member is added, disabled or removed.

### The content system's half

For a Payload project, `--cms=<dir>` (`cms=<dir>` on the verb) also writes the other half of the sign-in under `<dir>`, from the
same row, so the two halves cannot disagree:

| file | what it does |
|---|---|
| `endpoints/sso.ts` | the endpoint at `sso_target`: verifies the hand-off token, asks the host whether the person is still admitted, and mints an ordinary session; its `to` is held to a path under `cms_base` |
| `auth/membership.ts` | the host's membership question, remembered for a minute per email; fails closed, and uses the host's development secret when none is set outside production |
| `auth/sessionStrategy.ts` | verifies the session cookie on every request and asks the membership check again, so removing someone locks them out at once |
| `collections/Users.ts` | the users collection: no passwords, hidden, and not creatable over its API |

The files import `@hecks/client`, `jose` and `payload`, so they belong in the content system's project; without `--cms` nothing is
written there, and `--cms` on a project with no `Admin` row is refused. `--check` covers them like the other files.

The table is refused when `login` is not a public route, when `sso` is not an `admin` endpoint, when a path does not start with a
slash, when `roles` names none, or when `sso_target` is not under `<cms_base>/api/`, or when the row has a field this list does not.

## Files at the project root: `root=<dir>`

`--root=<dir>` (`root=<dir>` on the verb) writes the files that sit at a project's root, each only when its rows are
declared beside the route table. They are wiring, not domain: the rows say where things are, never what the domain does.

| rows | file |
|---|---|
| `Secrets` (`vault`, `item`; `section`; `launcher`, the script that starts the stack, named in the header), and `Env` rows (`name`; `value` for a plain setting (a number or true/false is written as it reads), `group` for a comment heading, `off` to comment the line out) | `.env.tpl`: a secret is an `op://` reference into 1Password, never a value |
| `Ci` (`gem_dir`; `name`, `ruby`, `node`, `script`, `test`, `paths`) | `.github/workflows/site-routes.yml`: runs `<script> --check` and the project's test, on the paths named plus the script, the lockfile and the workflow |
| `Cms` (`dir`, `node`, `port`, `heap_mb`, `dockerfile`), and `BootSecret` rows (`env`, `from`, `field`) | `<dir>/Dockerfile` (unless `dockerfile: false`, for a project that keeps its own image) and `<dir>/deploy-aws/boot.mjs`: the content system's image, and the script that resolves its secrets before the server starts |

| `Payload` (`domain`, `chapter`; `out`, `hecks`, `helpers`, `skip`), and `PayloadField` rows | `<out>/driver/lifecycle.ts`, `<out>/driver/specs.ts` and `<out>/collections/fields.ts`: the content system's way of driving the domain's aggregates, read from the domain itself |

A `BootSecret` fills the variable `env` from the secret whose id the variable `from` holds. With `field` the secret is JSON
and that field is the value; without it the whole secret is the value and failing to read it only warns. The database
password and the signing secret are always resolved. A row is refused when it has a field this list does not, when a
required field is missing, or when an `Env` row is a secret and there is no `Secrets` row to name its vault.

### Driving the domain from the content system

The `Payload` row names a domain (a directory under `--root` holding `bluebook/`) and the chapter to read. Every aggregate of
that chapter that has a lifecycle and a creating command is driven; `skip` lists any to leave out. Nothing is declared in
the domain: the generator reads it, and the editor-facing detail sits in `PayloadField` rows beside the route table, so the
domain never names the content system.

- `driver/lifecycle.ts` is the module that turns a saved document and a spec into the commands between the host's state and
  the wanted one, acting as the role the commands declare.
- `driver/specs.ts` holds, for each aggregate, its input type, how an input goes over the wire (a one-attribute value object
  as `{ value }`, `{ url }` or `{ address }`, an integer as `{ value: n }`, a list as a list, a composite as its parts), how the
  host's state reads back, the creating command with the status it leaves, and the lifecycle edges.
- `collections/fields.ts` holds, for each aggregate, a catalogue of Payload fields keyed by attribute and a reader that turns a
  saved document into the input. A collection picks and orders the fields and adds what the domain does not hold.

A `PayloadField` row says what an attribute's shape cannot: `kind` (`text`, `textarea`, `select`, `date`, `day`, `number`,
`upload`, `relationship`), `options` (`value=Label` pairs), `relation` and `via` for an upload or relationship, `field` when
the editor's name differs, `label` (`Singular|Plural`) for a list, `description`, `required`, `default`. A part of a composite is
`attribute.part`. An aggregate whose attribute is not a value object, or whose commands declare more than one role, is refused.

## The content editor: `editor=<dir>`

A project that edits its own content, without a third-party CMS, declares one `member` row of a `value_object "Editor"` beside
the route table and runs `--editor=<dir>` (`editor=<dir>` on the verb). The projection reads the row and the domain chapter it
names, and writes a small Node/TypeScript package under `<dir>`: a server (node's own `http`, no framework) whose pages and
forms are generated from the domain, not written per aggregate.

| field | what it is | default |
|---|---|---|
| `domain` | the domain's directory under the project, holding `bluebook/` | required |
| `chapter` | the chapter whose aggregates the editor edits, or several, comma separated (`Press, Library`); with several, the navigation groups them, addresses carry the chapter (`<base_path>/<Chapter>/<Aggregate>`) and verbs are sent as `Chapter::Aggregate.Verb` | required |
| `host_env` | the environment variable that holds the domain host's address | required |
| `login` | the site's login page, a public route: where a visitor with no session is sent | required |
| `base_path` | where the editor is served; it is the path the edge routes to the editor | `/editor` |
| `sso_path` | the endpoint the site's admin hand-off sends a signed-in admin to; under `base_path` | `<base_path>/api/sso` |
| `session_cookie` | the editor's own session cookie | `hecks_editor` |
| `host_cookie` | the host's account cookie name, when `HECKS_SESSION_COOKIE` is not set | `hecks_session` |
| `host_default` | the host's address when the variable is unset | `http://127.0.0.1:4322` |
| `roles` | the roles that count as an editor, comma separated | `Admin,Owner` |
| `title` | the editor's name in the browser tab (`<page> - <title>`) | `Editor` |
| `brand` | the product name the header and the navigation show, one line of at most 60 characters | the chapter's domain name |
| `accent` | a six-digit hex colour (`#1f7a6d`) the theme is derived from; refused when it is anything else | a deep verdigris, `#1f7a6d` |
| `logo` | a picture the header shows beside the brand: a relative path from the server's working directory to a `png`, `jpg`, `webp`, `gif`, `avif` or `svg` file, with no `..`, leading slash or hidden part; served to signed-in editors at `<base_path>/assets/logo` | none |
| `skip` | aggregates to leave out, comma separated; `Name`, or `Chapter::Name` for one chapter's | none |
| `chapter_roles` | roles a chapter is limited to, `Chapter=Role,Role;Chapter=Role`; its aggregates and its pictures are hidden from and refused to any other role (403) | none |
| `page_size` | how many instances a list shows to a page (1 to 1000); a page, a search (`_q`) and a state (`_status`) are in the address | `25` |
| `preview` | where a record is shown on the site, a URL template the editor frames in a side drawer: an `http(s)://` address or a path with one slash, with `{key}`, `{kind}`, `{slug}` and `{id}` filled from the record (a `<kind>:<slug>` identity is split; any other identity is the slug of `<snake-case aggregate>:<id>`). Refused when it is another scheme, names credentials, starts `//`, holds whitespace, an unknown placeholder or a placeholder in the scheme, host or port. Its origin (or `'self'` for a path) is the only `frame-src` the editor's content security policy gets | none |
| `zone` | the clock a moment held as text is entered in (`Z` or an offset such as `-07:00`); what a `PayloadField` `date` row on a text attribute means | `Z` |
| `preview_in` | `drawer` frames the preview in a side drawer; `tab` opens the site's page in a new tab, for a site that refuses to be framed (no `frame-src` is then sent) | `drawer` |
| `media` | another chapter of the domain whose picture aggregate the pictures use, when this chapter has none (a body here uses the pictures of that chapter) | none |
| `media_dir` | the directory the local-disk adapter keeps uploaded pictures in, from the server's working directory; used only when the chapter has a picture aggregate | `media` |
| `media_max_bytes` | the largest picture an upload may be, in bytes (1 to 104857600) | `5242880` |
| `upload_api` | the content system's API root (`/cms/api`) that a field marked as an upload sends its file to; its collections keep them, and the address the field holds is `<upload_api>/<collection>/file/<name>`. Needs `upload_env` | none (no upload) |
| `upload_env`, `upload_default` | the environment variable that names the content system's address for the editor's server, and the address when it is unset | none |
| `members_aggregate` | `Domain::Aggregate` of the people who may edit (an `email` and a `role` attribute, named by `members_email` and `members_role`). The editor reads it over the host's own protocol, which the host accepts from the same machine, and also asks the host's account route, instead of asking the members list that the host shows only to those who administer it. Without it, the members list is asked, and a person who may edit but not administer cannot sign in | none |
| `markdown_parse`, `markdown_render` | the site's own reader and renderer of its Markdown, each `<path relative to the editor's directory>#<exported name>`, imported when the editor is built so a Markdown field's preview is made by the code that makes the page. Both or neither | none (no preview) |
| `admin_roles` | the roles that manage who may edit: they get the People screen and its commands | `Admin,Owner` |
| `sign_in` | a path on the site's own origin that starts the host's sign-in (`/auth/google`). With it the editor has a sign-in page of its own (`<base_path>/login`), a person with no session is sent there instead of to `login`, and signing out also clears the site's own session cookie | none |
| `landing` | the path the host sends a person to once it has signed them in (`/admin.html`). The editor answers it with a redirect to its home, so route it to the editor at the edge: a person who may edit but not administer then arrives in the editor, not on the site's page that admits administrators only | none |

| file | what it does |
|---|---|
| `src/schema.ts` | the chapter's aggregates, attributes (kind, optional, list), value objects, lifecycles, commands (role, creating or acting on an instance) and queries, as one typed constant |
| `src/app.ts`, `src/server.ts` | the handler from a web `Request` to a `Response`, and the node server around it |
| `src/auth/*.ts` | the sign-in: the hand-off token, the membership check, and the editor's own signed session cookie |
| `src/ui/*.ts` | the server-rendered pages: the frame (header, navigation drawer, breadcrumbs), a list from a query, a detail page, a form per command, and the words and icons they share |
| `src/ui/body_*.js` | the read-only body: `bodyToHtml` / `htmlToBody` (pure, run in node and the browser) |
| `src/browser/*.js`, `src/browser/app.css` | what runs in the browser, and the stylesheet source: the shell, the forms, notices, the writing surface and the picture picker, built into `dist/` by `npm run build` |
| `src/assets.ts`, `src/flash.ts` | the static files (with ETags) and the one-shot notice cookie |
| `src/host.ts`, `src/commands.ts` | the `@hecks/client` wiring, and the running and judging of one command |
| `src/config.ts`, `package.json`, `tsconfig.json` | the row's settings, and the package |

The editor is generic by aggregate. A value-object attribute is a nested fieldset of its parts, a `list_of` attribute is a run of
repeatable rows (the rows it holds, then one blank to fill; a blank row is dropped), an optional part left blank is left out, and a
lifecycle state is a badge, never an input. A lifecycle move is offered only from the states it applies in. An attribute whose
type is a value object with a `blocks` list of a value object that has `kind` and `spans` (a structured document body, whatever
it is named) is edited on a writing surface (Tiptap): a toolbar and a page that edit the domain's own tree and post it as
the same dotted-path fields as any other value object. The list and detail pages show the body read-only, escaped. Pasted
HTML is reduced to what the body can hold, with a note saying what was reduced. ADR 0095's addenda have the details. A query that `returns` a value object is answered outside the domain and is not offered.

### Look, shell and build

The pages are server-rendered semantic HTML with Tailwind and daisyUI class names; `npm run build` (run by `npm start`) turns
`src/browser/app.css` into `dist/editor.css` and bundles `src/browser/main.js` into `dist/editor.js`, with the writing surface in a
chunk only a page with a body loads. The generated sources are a pure function of the chapter and the row, so `--check` covers
them; `dist/` and `node_modules/` are build output and are not committed. Before a build the pages are complete HTML with no
stylesheet or script, and still work.

- **Theme.** The row's `accent` makes two daisyUI themes, `editor-light` and `editor-dark` (used when the system prefers dark,
  or when the theme button has set one; the choice is kept in `localStorage`, and `theme.js` applies it before the page paints).
  Every text and fill pair is moved until it reaches the accessibility contrast ratios (4.5:1 for text, 3:1 for the edge of a
  control), whatever the accent. With no `accent` the neutrals are fixed; with one they take its hue.
- **Shell.** A header with breadcrumbs, the signed-in person and role, the theme button and sign-out; a navigation drawer open
  beside the page on a wide screen and behind the menu button on a narrow one, with the number each aggregate holds and the current
  page marked; a skip link and landmarks.
- **Lists** sort and filter in the browser (the page works without it), show status as words and a shape as well as a colour, and
  an empty list says so and offers the command that makes the first one.
- **Commands.** A command that asks for nothing and is safe runs from a button on the instance's page. One that asks for input has
  a page of its own. A command is destructive, and asks first in a native dialog, when its first word is `withdraw`, `retire`,
  `discard`, `delete`, `cancel` or `remove`, or when it is a lifecycle move into a state named `withdrawn`, `retired`, `discarded`,
  `deleted`, `cancelled`, `canceled` or `removed`. A browser with no script is sent to a page that asks the same question.
- **Notices.** A command that succeeds redirects with a signed, `HttpOnly`, one-minute cookie that the next page shows ("Published.",
  in the same verb as the button) and clears in its response; a refused one shows the refusal on the form and a notice.
- **Strict content security policy.** Every page is sent with `default-src 'none'; script-src 'self'; style-src 'self'; img-src
  'self' data: blob:; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`: no inline script or style,
  no other origin, no font or image from elsewhere. The writing surface is told to inject no style element, and its alignment and
  indent are data attributes, so it needs no `unsafe-inline`.

### Relationships, moments and long lists

What the editor derives is read from the bluebook, never from a name list of aggregates, so it can be predicted:

- **Chosen, not typed.** An attribute is offered as a choice of another aggregate's instances when: its `pattern` begins `^kind:` or `^(kind|kind):` (a `<kind>:<slug>` key: the kind is chosen, then the record of the aggregate whose snake-case name is that kind, if one is in the editor); or it is a `reference_to` attribute whose target is an editor aggregate; or it is a value object of one text part named `<Stem>Ref` where `<Stem>` is the type of an editor aggregate's identity attribute (`CategorySlugRef` and a `CategorySlug` identity) or an editor aggregate's name; or it is `ImageRef`, `PictureRef`, `PhotoRef` or `MediaRef` and the editor has a picture aggregate (suggestions only; any other text is accepted, since it may be an address). The target is the same chapter's aggregate if it has one, else the only one of that name; more than one gives no picker. What is on offer is the target's zero-argument query named `All`, `List`, `Listing` or `Active` (in that order), else every instance, labelled by its `title`, `name` or `label` attribute, else its identity, at most 500 of them. A strict key is checked against every instance the target holds before the command is sent; a key the form already names that is no longer on offer is kept.
- **Moments.** A single integer is a date when its attribute's, value object's or part's name ends in `_on` or `On`, and a date and time when it ends in `_at` or `At` or contains `epoch`. It is whole seconds since 1970 UTC; the form shows a native input in the person's time zone and says which, and a date is the start of that day. Read-only, the page writes the UTC time and the script restates it in the person's zone with how far away it is.
- **Lists.** A list shows `page_size` rows, a search over the identity and the title attribute (`_q`, every word must match), and a state filter for an aggregate with a lifecycle (`_status`); each page is a link. Sorting a page's columns stays in the browser. The navigation's counts are the lengths of the one read of the host that the page itself is made from (the host has no count to ask for). The last search and state used on an aggregate are kept for the browser tab.

### A record as one thing: related records, scheduling, preview and drafts

These are read from shape too, and each is absent when its shape is:

- **Related records.** Aggregate `B` is related to aggregate `A` when `B`'s identity is a `<kind>:<slug>` key (declared by its `pattern`) whose kinds include `A`'s snake-case name. `A`'s record page shows a panel for each such `B`: the record when it exists (a rich-text body as read-only text; a list of pictures as a strip of thumbnails in order; anything else as its fields) with an Edit link to the screen of the command that changes it, or an empty state with an Add link to the creating command's form with the key already filled. Both links carry `_back`, an address under `base_path` (anything else is ignored), so saving returns to the record with a notice.
- **Scheduling.** The first aggregate that has a `<kind>:<slug>` subject, a closed-set (`one_of`) action, a due time that is a moment, a lifecycle whose first state moves to at least two states that move nowhere, and a creating command that takes the subject, action and due time, is the scheduled-action aggregate. A record of an aggregate its subject names gets a Schedule panel (pending actions soonest first, a form, Reschedule on the command's own screen, Cancel behind a dialog, ended actions with their outcome and any reason) and the navigation gets a Scheduled screen of every pending action. The editor only makes and changes these records; it never runs an action. The query it uses to find a subject's actions is the one query whose single argument is the subject, else the read is filtered.
- **Preview.** The `preview` row field. Every record gets a Preview button except records of the picture and scheduling aggregates. The frame is `sandbox="allow-scripts allow-same-origin"`, so a site on another origin runs its scripts and keeps its own origin without being able to reach the editor; a path template is the editor's own origin, where that pair is no isolation, so use an absolute address for a site served elsewhere. The site must allow the editor to frame it (`frame-ancestors`).
- **Drafts.** A command on an aggregate whose every argument is `draft_<x>`, where the aggregate holds both `draft_<x>` and `<x>` of one type and some `<x>` is a rich-text body, a list of mixed blocks or a value object (alone or in a list), saves a draft; the form of a value object saves as a whole. The body editor on its screen saves by itself after five seconds without typing and on blur, only when something changed and the form passes its checks, by a form post the server answers in plain text; it only ever runs that command, never the live attribute. The command that `sets <x>, to: state(:draft_<x>)` publishes it, and the one that only empties `draft_<x>` discards it; each asks first and publishing saves what is unsaved first.
- **Pages of a fixed structure.** A value object with a media key and an `alt` is a picture wherever it sits (the picker, the description required, `picture` in the schema). A text an invariant bounds (`summary.to_s.size <= 600`, `size` or `length`, optionally after `summary.unset? ||`) carries `maxLength`, and above 200 characters is a writing box. A list's `size >= n` and `size <= n` in the holder's invariants, or a command's `given`, are shown beside it and held by the add control. A list whose members hold a body or a picture at any depth is cards made from a template, a list in a member a group one level in; other lists stay rows. A refusal that names a value object marks the card and the field it is about, found by the value it echoes.
- **A list of mixed blocks.** A `list_of` value object that has a discriminator, a part typed as a closed set (`one_of`) of one plain value or a text part that an invariant restricts to a literal list, is drawn as ordered cards: the kind, one line that says what the block holds, move up and down (announced in a polite live region), remove (after a question) and, when opened, the slots its kind uses. The kinds come from the closed set. Which slots each kind uses comes from a closed set of rows in the same aggregate with the parts `kind`, `requires` and `uses` (slot names, comma separated), one row per kind; a slot no row names belongs to every kind, and naming `media_ref` brings `alt`. With no such table every slot is shown and the invariants of the form `kind != "<k>" || ...` only mark which slots a kind's rules read. A limit comes from an invariant or a `given` written `<list>.size <= <n>`. A picture is a value object's `media_ref` with `alt` (and `caption`), drawn together with the picker. Repeated parts (buttons, entries) are groups of cards one level in; a body inside a card gets its writing surface when the card is first opened. The whole list is sent in the order shown, an empty row is dropped, and a refusal of an invariant is matched to the block whose value it echoes and marks that card and the slots it names. The declared table changes what an editor shows, never what the domain accepts.

When the chapter has an aggregate that registers pictures, the editor also uploads and serves them. The aggregate is found by shape,
not by name: a creating command whose attributes are the aggregate's identity (the key), an alt text (`alt` or `alt_text`) and a
mime type (`mime_type`, `mime` or `content_type`), optionally `width` and `height`, with every other attribute optional; the
aggregate's query with no arguments lists the pictures. The domain keeps the record, never the bytes. `src/media/` holds the upload
(a bounded read, an allow-list of JPEG, PNG, WebP, GIF and AVIF decided by the first bytes, the size cap, alt text required), the
storage port (`put`, `url`, `read`) and its local-disk adapter, which writes `<sha256>.<ext>` under `media_dir`. A project that
keeps pictures in an object store implements the same interface and passes it as `createApp({ storage })`. Pictures are served to
a signed-in editor only at `<base_path>/media/<key>`, for keys of the generated form, with `X-Content-Type-Options: nosniff`. The
writing surface's image button opens a picker (`src/browser/media_picker.js`). A chapter with no such aggregate has none of this, and the image
button keeps its prompts.

The server is a sidecar: it is the host's `/dispatch` caller, which the host honours only from the same machine, so it
authenticates every person itself. A visitor with no valid session is sent to `login`; the site's admin hand-off sends a signed-in
admin to `sso_path` with a short-lived account token, which the server verifies with the secret it shares with the host
(`AUTH_SECRET`, the host's `SESSION_SECRET`), and a session starts only when the host's members list holds the person with one of
`roles`. The members list is asked again on every request (remembered for a minute), so removing someone locks them out. Posts
from another site are refused. Set the Admin row's `cms_base` to `base_path` and `sso_target` to `sso_path` so the hand-off lands
here.

The host answers HTTP 200 whether or not the domain refused, so a command's outcome is judged by the state that comes back, and a
refusal is shown on the form with the person's input kept (a `given` as "Not allowed unless ...", an invariant as the field and its rule). Commands run as the role they declare. An optional command argument that only clears a field (`sets :draft, to: :nothing`, never otherwise read) is not offered as an input. The header has a sign-out button (`POST <base_path>/logout`). The generated `package.json` pins `@hecks/client` to this hecks's own version.

The row is refused when `login` is not a public route, when `base_path` or `sso_path` is malformed or `sso_path` is not under
`base_path`, when `roles` names none, or when the row has a field this list does not. `--editor` on a project with no `Editor` row
is refused. `--check` covers the files like the others.

### The words an editor says: jobs, labels, help and what is kept behind "More options"

The domain's names say what the model is, not what a person does, so the editor's home page is a card of jobs for each
aggregate ("New event", "Edit events") and its labels and help are declared beside the route table, on the site's side,
as three more value objects of the route chapter. The domain's bluebook stays free of all of it. Each is optional, and a
row that names an aggregate, command or attribute the chapters do not have is refused, naming every such row at once.

| value object | what a row says |
|---|---|
| `EditorThing` | `aggregate` (`Name` or `Chapter::Name`; a chapter's name titles that chapter in the navigation), `name` (one, lower case: "event"), `plural`, `about` (the sentence under the card; the bluebook's `description` otherwise), `preview` (this aggregate's own preview address, see below), `advanced` (the card goes under "More" on the home page and in the navigation) |
| `EditorField` | `aggregate`, then `attribute` (`part` for a part: `sessions.starts_on`) or `command` (alone, the command's button: `label`, and `help` under it; with `attribute`, the row is about that command's form only). `label`, `help`, `kind`, `zone`, `advanced`, `picks`, `fill`: see below |
| `EditorCompanion` | `aggregate`, `with` (another aggregate), `key` (a template; `{slug}` is the record's identity), `field` (the text of the companion that is edited), `when` (`<attribute> is <value>` or `<attribute> includes <value>`), `label`, `help` |

**`PayloadField` rows are read first.** A project that already declares `PayloadField` rows for a content system has said most of
this: the editor reads the same rows, so a field's words are written once. A row's `label` (a list's is `Singular|Plural`) is
the caption (and the name of one row of the list), `description` is the help under it, `kind` `textarea` is a writing box,
`select` with `options` (`value=Label` pairs or bare values) is a choice with its words, `date` on a text is the clock of the
`Editor` row's `zone` and on a whole number is a date and time (`day`: a date), `relationship` is a choice of the aggregate its
`relation` collection names (`practice-texts` is `PracticeText`), `required: false` shows "optional" (an empty value is still
sent, as the content system sends it) and `default` is what a new record starts with. An `upload` is read for its words only:
the editor has no store for files of its own, so it stays a text input. A row that names an aggregate the editor does not edit,
or an attribute the chapters lack, is skipped here (the content system's projection refuses it). `EditorField` rows are
applied after and win; they hold only what `PayloadField` cannot say (advanced, fill, a command's button, and aggregates the
content system's rows do not drive). The `Editor` row's `zone` (`Z` or an offset, default `Z`) is the clock moments held as
text are entered in.

What the home page and the pages take from the model without a row:

- **The words of a job.** A card is the aggregate (its `about` row, else its `description`). Under it, "New <name>" for each
  command that makes a record (not one a `System` role runs) with the command's own `goal` as the sentence beside it, and
  "Edit <plural>" for the list. An aggregate whose identity's value object is one literal (`value == "site"`) holds one
  record: the card offers "Change <name>" straight to it, and no "New".
- **Buttons.** A record's page lists the commands that apply now, each with its `goal` under it. A row's `label` replaces the
  humanised command name. Publish and discard of a working copy are offered only when a draft is saved, and a saved draft is
  shown on the record's page above the live content.
- **A related record by its name.** An attribute is a choice of another aggregate's records, shown by title and storing the key,
  when it is a value object of one text part that is spelled as the type of that other aggregate's identity
  (`PracticeTextSlug` on an event, where a practice text is identified by a `PracticeTextSlug`), as well as by the earlier
  rules (a `<kind>:` pattern, `reference_to`, a `<Stem>Ref`). An aggregate's own identity is never a reference to itself. When
  the model's names say nothing, a row's `picks` names the aggregate.
- **A closed set written as one invariant.** `invariant("...") { value == "a" || value == "b" }` is a choice of `a` and `b`,
  as a `one_of` is.

What a row's fields do:

| field | effect |
|---|---|
| `label`, `help` | the input's caption and a sentence under it, the refusal's own wording uses the label |
| `kind: "textarea"` | a writing box of several lines for a plain text. The model's own way is a bound, `invariant("at most 600 characters") { value.to_s.size <= 600 }` on the value object that holds the text (or a command's `given`): the part carries `maxLength` and, above 200, is a box with the limit. The row is for a text the model does not bound |
| `kind: "datetime"`, `zone` | the attribute is ISO 8601 text and is entered as the clock of `zone` (`Z` or an offset such as `-07:00`) in a `datetime-local` input; it is stored with the zone's offset and a time the person did not change is sent back exactly as it was held |
| `kind: "markdown"` | the text is written in Markdown: a toolbar for exactly what the site's reader understands (headings one to four, bold, italic, a link, bulleted and numbered lists, a list inside a list, a line break, a character written as a number so it shows as itself), a note of what can be used, and, with `markdown_parse` and `markdown_render`, a preview made by the site's own code |
| `kind: "image"` or `"file"`, `picks` | the attribute holds the address of a picture (or a PDF) kept by the content system's collection `picks` names (`media`, `documents`). The field has a way to choose a file, describe it (required: the content system keeps it as the file's description), send it and see it, and takes the address it comes back with. A `PayloadField` row with `kind: "upload"` and a `relation` says the same, with `options: "pdf"` for files; one with no relation is words only |
| `after` | the attribute ends a range that starts at the attribute it names; an end before its start is refused before anything is sent. Without a row, an attribute named `ends_*` ends the one named `starts_*` (at the top of a command or in the parts of a list's rows) |
| `advanced: true` | kept behind "More options" on the form |
| `fill` | what the editor puts in when the input is left blank: `now` (seconds since 1970), `slug_of:<attribute>` (an address made from another attribute), `part:<attribute>:<separator>:<index>` (one piece of another attribute's text). A filled attribute is behind "More options" |
| `picks` | the aggregate the attribute names |

A companion record is the text that belongs to a record but is held as a record of its own (the body of an event is the
`body` of the content block keyed `event.<address>.body`). It is shown on the record's page as a panel: its text with an
Edit link to the companion's own command, or an empty state that opens the creating command with the key filled in and the
way back to the record. The first row for an aggregate and label whose `when` holds is the one shown.

A `preview` may also be given per aggregate by `EditorThing`; with `preview_in: "tab"` the record's page has a "View on the site"
link that opens it in a new tab. Previews that are framed must share one origin (a path is the editor's own).

#### What a picture's key is written as

A picture slot's key (`media_ref`) is written as the picker's key, a bare `<sha256>.<ext>`, unless the model's pattern for
it begins with a literal such as `^media:`, in which case the editor writes that literal first (`media:<key>`). Either
spelling is read back: the thumbnail and the picker find the picture by the key without the prefix. A site that renders
the picture should do the same: strip a leading `<word>:` and look the key up. The picker's alt text is the chosen picture's
own registered description unless the person has typed one, and the caption of the picture being replaced is not carried over.

#### Refusals

A refusal is shown in the field's own label and the rule, not the domain's type names. A rule about a block of a body marks
the body, and a value that is the wrong shape (`Type.part must match ...`, `Type.part expects String, got nil`) is "<label>
is not in the form the site needs" (with the row's `help`) or "<label>: <part> is needed". A mark of a refusal comes off when the
person changes what it names: a field when it is given text, a card (and the summary at the top of the list) when anything in it
changes, and the page's notice when a draft is saved; the next save marks what is still wrong.

## Projecting it

```
hecks site site_projection.project_site <project> [out=<dir>] [template=<file>] [cms=<dir>] [root=<dir>] [editor=<dir>] [extension=ts|mts] [--check]
```

It runs from a project, with the installed gem; it needs no hecks checkout. Three places are independent of one another:

| what | where | default |
|---|---|---|
| the chapters | `<project>/bluebook/`, and the `<project>/vendor/` they attach from | the project is the argument |
| `routes.ts` | the directory `out` names, anywhere | `<project>/generated` |
| the template | the file `template` names, anywhere; rewritten in place | the `Edge` row's `template:`, relative to the project |

Relative paths are read from where the command runs. The `Edge` row's `template:` may be left out when `template` names the file. When
`out` is given and `template` is not, `out` also receives a copy of the Edge row's template at the same relative path and the project's
own is left alone, which is how a project previews a change. The command refuses: an `extension` outside `ts`, `mts`; an `out` that is a
file; a `template` that does not exist, or one named for a project that declares no Edge rows; and an Edge row's `template:` that is
absolute or climbs out of the project with `..` (name the file with `template` instead).

With `--check` nothing is written: the command exits 1 and names each file that differs from the table, so a CI job fails on drift. The
file starts with `// Generated by hecks site site_projection.project_site. Do not edit.`, holds no time or machine, and is the same
text on every run.

`extension=mts` writes `routes.mts` instead of `routes.ts`, with the same text. The module is an ES module either way; the `.mts`
name is what lets Node import it (`import * as site from "./routes.mts"`) from a package whose `package.json` says
`"type": "commonjs"`, where Node reads a `.ts` file as CommonJS.

## Routes from the domain

A row whose source is `command:Studio.Inquiry.Submit` takes its path from the forms scheme, so the site and the
`hecks present` forms agree on one URL for it: `/Studio/Inquiry/Submit`. The command or query must exist in a
chapter the project attaches. The scheme covers a command or query of an aggregate; it does not name an entity's
command or a report, and a project lists the domain routes it exposes, since `Forms.configure` exposes a whole
chapter rather than a command.

## The edge: CloudFront behaviours and listener rules

The same table decides how the CDN and the load balancer treat each path, so a path is not named a second time
in the infrastructure template. A project adds `member` rows of four more value objects of its route chapter,
for the facts only its template knows, and marks two regions in the template it owns.

| value object | fields |
|---|---|
| `Edge`, one row | `template` (the CloudFormation file, relative to the project), `listener` (a reference to the listener), `secret_header` with `secret_value` (the header the distribution adds; every rule requires it), and `alb` (`false` when the project has no load balancer; true by default). |
| `EdgePolicy` | `cache_class`, optionally `origin` (it then applies to that origin only), and `cache`, `origin_request`, `response_headers`. A policy is a managed one by name (`caching_disabled`, `caching_optimized`, `all_viewer`, `all_viewer_except_host`), a policy id, or an intrinsic such as `!Ref PagePolicy`. |
| `EdgeOrigin` | an `origin` and the CloudFront origin `id` it is, and for a server behind the load balancer its `target_group`. |
| `EdgeRule` | a listener rule's logical id (`rule`), its numeric `priority`, and the `origin` it forwards to. |

```yaml
        # BEGIN GENERATED site_cdn behaviors
        # END GENERATED site_cdn behaviors
```

The template holds one `behaviors` region, where `DefaultCacheBehavior` and `CacheBehaviors` go, and one
`listener_rules` region, where the listener rules go; a project with no load balancer has the first alone (below). Everything between the markers is rewritten on each run, at
the markers' indentation; the rest of the template, and any comment about why a path is routed as it is, stays the
project's and belongs outside the markers. `--check` compares the regions too, so a template edited by hand in a
region is named as out of date.

How a route becomes a behaviour:

- The row for `/*` is the default behaviour, and the rule it names with `alb_rule` is the website's, written with
  no path condition. A table needs that row.
- A parameter in a path (`/pay/:id`) is a `*` to the edge.
- A route needs a behaviour only when the one CloudFront would match for its path anyway, the nearest broader
  route's or else the default, differs from the one the route resolves to. Pages cached like the default produce
  none; the pages under `/admin*` produce none beside `/admin*`; `/pay/*` does produce one, as a `no_store` route.
- The behaviour comes from the row: the origin names the CloudFront origin and the `EdgePolicy` for the cache
  class on it; the methods are the set CloudFront allows that covers the row's (`GET` alone is read, anything
  else all, and an assets origin is read without `OPTIONS`); a public read-only page on the website or the assets
  may be asked for over http, anything else is https-only.
- Order is the order the rows are declared in, which is the order CloudFront matches in. A route that a broader
  one declared earlier would shadow is refused, naming both. Two rows on one pattern with different verbs share
  one behaviour.
- A route on the cms or the domain needs an `alb_rule`, unless a broader route of the same origin has one
  (`/cms/*` carries `/cms/_static/*`). A rule holds at most four paths when it requires the secret header, since
  an ALB rule holds five condition values in all. A rule is refused that carries no route, that a lower-numbered
  rule of another origin would answer first for one of its routes, or whose priority another rule shares.
- `cdn: false` keeps a route out of the behaviours and in its rule: a path only the site's own server reaches.
- `edge_methods` separates the verbs the edge lets through from the verbs the route answers. A route's `methods` are its own, as
  `routes.ts` reports them: an admin page answers `GET`. The edge allows what the behaviour that carries the page allows, which
  for a page under `/admin*` is `GET,POST`, so the page says `edge_methods: "GET,POST"` and, with the prefix's cache class, makes no
  behaviour of its own. Without `edge_methods` the edge allows the route's `methods`, as before. `edge_methods` must include
  every one of the route's `methods`. `routes.ts` does not carry it.

### A site with no load balancer

A project behind Caddy or any other proxy has no ALB, and no listener rules to write. Its `Edge` row says `alb: false`:

```ruby
member template: "deploy/template.yaml", alb: false
```

The template then has no `listener_rules` region and the command writes none; a template that still holds one is refused so the
stale rules are removed. `EdgeRule` rows and `alb_rule` on a route describe a load balancer, so they are refused while the
project says it has none; `listener` and `target_group` are ignored. What is still checked is
that every route reaches an origin: a route on the cms or the domain needs an `EdgeOrigin` that maps its origin, whether or not the
CDN fronts it, and its cache class needs an `EdgePolicy`. A project with a load balancer is unchanged.

Each refusal names every problem at once, as the table's do: an origin that no `EdgeOrigin` maps or the Site
chapter does not know, a cache class no `EdgePolicy` maps, a policy reference that is none of the three forms, a
duplicate priority or rule name, a shadowed pattern.

Regions rather than whole fragment files, because a CloudFormation template is one document: the behaviours are a
property of the distribution among its origins, certificate and logging, and the rules are resources beside the
listener and the service that depends on them. A fragment would need an include transform and a bucket to hold it.
With `out=<dir>` a copy of the template is written beneath it at the same relative path, and the project's own is
left alone.

### Checking a running site

`hecks site site_projection.check_site <project> url=<https://example.org>` asks a running site what the route table says
it must answer. It sends anonymous requests, follows no redirect, and changes nothing, so it is safe against production.
What it asks follows from each row:

- an `admin` route is asked without a session, with each of GET and POST it takes, and must answer a redirect, 401 or 403;
  a redirect must not be explicitly cacheable (`public`, or a `max-age` above 0, without `no-store` or `private`)
- a `public` page that is indexable must answer 200 and carry `<link rel="canonical">`
- a row that is `off` must answer 404
- a `redirect` row with `redirect_to` must redirect there
- a path no row declares must answer 404

A route that names a parameter or a prefix (`/blog/:slug.html`, `/auth/*`) has no one URL to ask and is left out. The
command prints a line per check and exits 1 when any answer is wrong. Checks that need a session, a write or the site's
own wording stay in the project's smoke.

### Checking that a host enforces roles

`hecks site site_projection.check_roles <project> url=<http://127.0.0.1:port>` takes the commands a project declares a
`role` for (read from its bluebooks, vendored chapters included) and dispatches each to a running host's `/dispatch` with
no role and no actor. A host checks that arguments are present and well-typed before it asks who is calling, so each
command is sent with arguments synthesized from its declaration. A host running with `HECKS_ROLE_ENFORCEMENT=enforce`
refuses every one as `Unauthorized`; a command that is accepted, or refused for another reason, fails the check.

A command whose synthesized arguments the host itself refuses (a value object with a pattern or an invariant the
placeholder does not meet) never reaches the role gate. It is reported as unchecked and does not fail the run, so the
summary reads `N commands, F failed, U unchecked`. The verb prints a line per command and exits 1 on any failure.

A host that does not enforce roles would run the commands, so the verb asks only a host on this machine, the one a spec or
a CI job started for the purpose, and refuses any other address.

### Checking the live distribution

`hecks site site_projection.check_live <project> live=<file> | distribution=<id> [template=<file>]` compares the behaviours the project's edge
generates with those of a live CloudFront distribution, and changes neither. `live=` is a saved answer of
`aws cloudfront get-distribution-config`; `distribution=` fetches it with that one read-only call, so the command needs
`aws` and permission to read the configuration, and nothing else. Name exactly one.

A behaviour is matched by its path pattern (`(default)` for the default behaviour) and compared on its origin, allowed
methods, cached methods, viewer protocol, compression, and cache, origin request and response headers policy ids. The
command exits 1 and prints a line for each difference: a behaviour only the project or only the distribution has, a field
that differs, and behaviours the two put in a different order.

A policy the edge names by an intrinsic (`!Ref PageCachePolicy`) is a resource of the stack, while the distribution holds
its id. Say what each stands for with `refs="!Ref PageCachePolicy=<id>,!Ref StaticHeaders=<id>"`; a reference with no entry
cannot be compared, is listed as unchecked, and fails the check. `expect_new=/pay/*,/thanks` names behaviours a pending
deploy adds: they are reported as expected additions and do not fail the check. A behaviour only the distribution has is
never expected.

`template=<file>` stands in for the `Edge` row's `template:` exactly as it does for `project_site`, so a project that leaves
the row's `template:` out can still be checked. The check reads no template, so the file need not exist.

Because the check is `settled`, no `--wait` is needed. It prints the report alone, not the whole record: a distribution that
matches prints the line saying so and exits 0, one that does not prints a line for each difference and exits 1.

## What a record's own form carries, and what the editor refuses before it sends

These are the editor's own courtesy, not the domain's rules: a model that has no such rule still accepts what the form refuses from any other client, and the editor says nothing it cannot see in the declarations.

- **The text that goes with a record is on its form.** An `EditorCompanion` row of a record's text gives the form that makes the record (and the one that edits it, the command that takes the most) one more box, named `__text.<n>`. The record is saved first and then its text, as the roles each command declares. A text that did not change is not written again; a blank one for a record that has no text yet makes none. When the text is refused after the record was kept, the person is told that the record is saved and the text is not, the form that edits the record is shown with what they typed and the refusal marked, and nothing is saved twice.
- **An address is not taken twice.** A creating command whose identity a record already holds is refused with "That address is already used by `<title>`" (the title, name, heading or label attribute, else the address itself) and the field marked; the record is never overwritten.
- **A range that ends before it starts** is refused with the end marked, or the row of a list named, before anything is sent. The same moment is allowed.
- **A file is checked by its bytes.** A picture is JPEG, PNG, WebP, GIF or AVIF and a file is a PDF, by their first bytes and not by the name or the type the browser sent; `media_max_bytes` caps the size; a description is required. The file is sent to the content system as the signed-in person (the editor exchanges a short account token for the content system's own session at `<upload_api>/sso`), kept under a name made of letters, digits, dot, dash and underscore, and the field is given the address it answers with.
- **A person who may edit but not administer can sign in.** With `members_aggregate` the editor reads the people over the host's own protocol, and a person signed in on the site, who reaches the editor's address with the site's own session cookie, is admitted by the same list. An unadmitted person is told so on a page of the editor.

## A working desk: scheduled actions that run, history, a library, people, sign-in and a preview

These are generic: they read the chapters and the rows, name nothing of a project, and run in the editor's own process.

- **Scheduled actions run.** The scheduled-action aggregate is found by shape (see the scheduling bullet above). A package that
  says neither which records its subject may name nor which actions there are is told by two `EditorField` fields:
  `keys` (comma separated kind words, each the snake-case name of an aggregate, such as `event,post`) on the subject,
  and `options` (`a,b` or `a=Label,b=Label`) on the action. An `EditorRun` row (`aggregate`, `action`, `command`) says what a
  due action does to a record of an aggregate: `command` is a comma separated list tried in order, and the first that applies
  to the record's state runs, through the host as any save, so the domain's rules apply. The runner (`src/runner.ts`) looks every
  `EDITOR_RUN_EVERY` seconds (30 unless set; 0 turns it off) at the waiting actions whose time has come, soonest first, does
  each, and reports back with the aggregate's own commands: the move to a final state that takes nothing is "done", the one that
  takes only the reason is "failed" with the reason in words. A record already in the state the action wants is done; one
  that cannot be moved is failed, and nothing is retried. The record that schedules is the package's own, so whether it also
  needs an era is the project's: a package that adds an aggregate to a chapter changes its shape.
- **A moment on a zone's clock.** An `EditorField` row `kind: "datetime"` with a `zone` on an integer moment shows and enters it
  as the clock of that zone (`-07:00`) and stores the same instant in whole seconds, instead of the viewer's own zone.
- **History and putting a change back.** Every command the editor sends that the host accepted is kept in
  `EDITOR_HISTORY_FILE` (default `data/history.jsonl` beside the editor, so the box must give the editor a directory that
  survives a restart): when, the signed-in person, the command, the record before and after. A record's page lists them, with
  what changed, and for a change that was an edit (a command that takes values and is not a move) a button that sends the
  same command the values the record held before. A working copy saved as the person writes is not listed. It is "changes made
  through this editor": the host stores no events a person can read back on the Rust host and drops who made a change, so a
  change made another way is not in it.
- **Pictures and files already uploaded.** The Pictures and files screen lists what the content system keeps (a page of 24,
  searched by description or file name, newest first), asked as the person, with a small picture and where each is used (every
  record whose values hold the address). A picture or file field has "Choose one already uploaded". The sizes the content
  system makes of a picture on upload are its own; the editor sends the file through its API so they are made.
- **People.** For `admin_roles`: the list (the host's own members list, asked as the person, which alone says who is turned
  off), add a person with a role (`Admit` then `GrantAccess` of the `members_aggregate`), change a role, and turn a person off
  and back on through the host's own route, whose rules (not yourself, not the last administrator) answer in its words. A role
  change that would leave no administrator is refused by the editor, since it does not pass through that route.
- **Sign-in.** See `sign_in` and `landing` above. Google is the only way in on the host; the editor starts it and admits whoever
  the session cookie it sets names and the people list holds.
- **A preview the editor draws.** A form of a record the site has a page for has "Preview (approximate)": the values as typed,
  over the record as it is, laid out as a page in a new tab without saving, with the text made by the site's own renderer in
  the browser and a link to the record on the live site. A site that sends `X-Frame-Options: DENY` cannot be framed, and a draft
  is not on it, so this is the editor's own drawing and says so.
- **Help.** A page generated from the same words as the screens: for each aggregate what it is, the fields of each form with
  their help and whether they are needed, and what each button does.
