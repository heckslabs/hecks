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
| `chapter` | the chapter whose aggregates the editor edits | required |
| `host_env` | the environment variable that holds the domain host's address | required |
| `login` | the site's login page, a public route: where a visitor with no session is sent | required |
| `base_path` | where the editor is served; it is the path the edge routes to the editor | `/editor` |
| `sso_path` | the endpoint the site's admin hand-off sends a signed-in admin to; under `base_path` | `<base_path>/api/sso` |
| `session_cookie` | the editor's own session cookie | `hecks_editor` |
| `host_cookie` | the host's account cookie name, when `HECKS_SESSION_COOKIE` is not set | `hecks_session` |
| `host_default` | the host's address when the variable is unset | `http://127.0.0.1:4322` |
| `roles` | the roles that count as an editor, comma separated | `Admin,Owner` |
| `title` | the editor's name in its header | `Editor` |
| `skip` | aggregates to leave out, comma separated | none |
| `media` | another chapter of the domain whose picture aggregate the pictures use, when this chapter has none (a body here uses the pictures of that chapter) | none |
| `media_dir` | the directory the local-disk adapter keeps uploaded pictures in, from the server's working directory; used only when the chapter has a picture aggregate | `media` |
| `media_max_bytes` | the largest picture an upload may be, in bytes (1 to 104857600) | `5242880` |

| file | what it does |
|---|---|
| `src/schema.ts` | the chapter's aggregates, attributes (kind, optional, list), value objects, lifecycles, commands (role, creating or acting on an instance) and queries, as one typed constant |
| `src/app.ts`, `src/server.ts` | the handler from a web `Request` to a `Response`, and the node server around it |
| `src/auth/*.ts` | the sign-in: the hand-off token, the membership check, and the editor's own signed session cookie |
| `src/ui/*.ts` | the server-rendered pages: a nav of aggregates, a list from a query, a detail page, a form per command |
| `src/ui/body_*.js` | the rich-text body: `bodyToHtml` / `htmlToBody` (pure, run in node and the browser) and the widget |
| `src/host.ts`, `src/commands.ts` | the `@hecks/client` wiring, and the running and judging of one command |
| `src/config.ts`, `package.json`, `tsconfig.json` | the row's settings, and the package |

The editor is generic by aggregate. A value-object attribute is a nested fieldset of its parts, a `list_of` attribute is a run of
repeatable rows (the rows it holds, then one blank to fill; a blank row is dropped), an optional part left blank is left out, and a
lifecycle state is a badge, never an input. A lifecycle move is offered only from the states it applies in. An attribute whose
type is a value object with a `blocks` list of a value object that has `kind` and `spans` (a structured document body, whatever
it is named) is edited with a rich-text widget: a toolbar and a contenteditable surface that edit the domain's own tree and
post it as the same dotted-path fields as any other value object. The list and detail pages show the body read-only, escaped.
Pasted HTML is reduced to what the body can hold, with a note saying what was reduced. The widget's browser code is plain
`src/ui/body_*.js`, served to a signed-in editor under `<base_path>/assets/`; ADR 0095's addendum has the details. A query that `returns` a value object is answered outside the domain and is not offered.

When the chapter has an aggregate that registers pictures, the editor also uploads and serves them. The aggregate is found by shape,
not by name: a creating command whose attributes are the aggregate's identity (the key), an alt text (`alt` or `alt_text`) and a
mime type (`mime_type`, `mime` or `content_type`), optionally `width` and `height`, with every other attribute optional; the
aggregate's query with no arguments lists the pictures. The domain keeps the record, never the bytes. `src/media/` holds the upload
(a bounded read, an allow-list of JPEG, PNG, WebP, GIF and AVIF decided by the first bytes, the size cap, alt text required), the
storage port (`put`, `url`, `read`) and its local-disk adapter, which writes `<sha256>.<ext>` under `media_dir`. A project that
keeps pictures in an object store implements the same interface and passes it as `createApp({ storage })`. Pictures are served to
a signed-in editor only at `<base_path>/media/<key>`, for keys of the generated form, with `X-Content-Type-Options: nosniff`. The
widget's image button opens a picker (`src/ui/media_picker.js`). A chapter with no such aggregate has none of this, and the image
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
