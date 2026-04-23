# Hecks — The Narrative

> This document drives both the README and the demo script.
> Each section is a beat in the story. The README renders it as prose.
> The demo script adds timing markers and exact commands.

---

## 1. The Hook

Hecks is a domain compiler. Describe your business once. Generate complete applications in Ruby, Go, or Rails. Zero runtime dependency. The output is yours.

```bash
$ gem install hecks
$ hecks mcp
```

Hecks is AI-native. The MCP server lets Claude model domains, run commands, and generate applications alongside you.

---

## 2. Sketch

Hecks comes with a console for building domains. You sketch, then you play.

```bash
$ hecks new blog
$ cd blog
$ hecks console
```

```ruby
hecks(sketch)> Post
Post aggregate created

hecks(sketch)> Post.title String
title attribute added to Post

hecks(sketch)> Post.status String
status attribute added to Post

hecks(sketch)> Post.lifecycle :status, default: "draft"
lifecycle added to Post on status, default: draft

hecks(sketch)> Post.transition "PublishPost" => "published"
PublishPost transition added -> published

hecks(sketch)> Post.transition "ArchivePost" => "archived"
ArchivePost transition added -> archived

hecks(sketch)> Post.create
CreatePost command created on Post

hecks(sketch)> Post.create.title String
title attribute added to CreatePost -> CreatedPost
```

Blogs need comments.

```ruby
hecks(sketch)> Comment
Comment aggregate created

hecks(sketch)> Comment.post_id reference_to("Post")
post_id reference added to Comment -> Post

hecks(sketch)> Comment.author String
author attribute added to Comment

hecks(sketch)> Comment.body String
body attribute added to Comment

hecks(sketch)> Comment.create
CreateComment command created on Comment

hecks(sketch)> Comment.create.post_id reference_to("Post")
post_id reference added to CreateComment -> Post

hecks(sketch)> Comment.create.author String
author attribute added to CreateComment -> CreatedComment

hecks(sketch)> Comment.create.body String
body attribute added to CreateComment -> CreatedComment
```

---

## 3. Play

```ruby
hecks(sketch)> play!
```

> `Entering play mode (2 aggregates, 2 commands)`

```ruby
hecks(play)> Post.create(title: "Hello World")
```

> `CreatedPost { title: "Hello World", status: "draft" }`

```ruby
hecks(play)> Post.publish(post_id: Post.all.first.id)
```

> `PublishedPost { status: "published" }`

When we like it, we save it.

```ruby
hecks(play)> export
```

> Wrote `hecks_domain.rb` — the source of truth. Everything generates from this.

---

## 4. The Web Explorer

```ruby
hecks(play)> serve!
```

> `Serving BlogDomain on http://localhost:9292`

Open the browser. Create a post. Watch the lifecycle badge change from "draft" to "published." Add a comment — the Post dropdown shows your posts. Check the event log.

Notice: these are domain events, not framework events. `CreatedPost`. `PublishedPost`. `CreatedComment`. This is your ubiquitous language.

---

## 5. Claude Takes Over

Let Claude drive.

> "Build me a photo gallery domain. Photos have a title, url, taken_at date, and tags. I need upload, tag, and archive commands."

Claude generates the domain via MCP. Every operation shows its result.

> "Wouldn't it be nice if both apps could share the same comments system? Promote Comments into its own domain. Wire it into both Blog and Photos."

Claude promotes Comments, creates the new domain file, wires `extend` on both consumers.

> "When I upload a photo, I want a draft blog post created automatically."

Claude adds one policy:

```ruby
policy "AutoDraft" do
  on "UploadedPhoto"
  trigger "CreateDraftPost"
  map title: :title
end
```

One policy. Three domains talking to each other through events. Upload a photo, a draft post appears. The event log shows the chain: `UploadedPhoto → AutoDraft → CreatedDraftPost`.

---

## 6. Extend

One reason this is so fast: everything is in memory. Let's fix that.

```ruby
extend :sqlite
```

Oops, we need to push a first release and we don't have multitenancy.

```ruby
extend :tenancy
```

Oops, it's selling like hotcakes. We need a real database.

```ruby
extend :postgres
```

And my developers want Slack notifications.

```ruby
extend :slack, webhook: ENV["SLACK_URL"]
```

The company just got acquired. They need to consume our events in real time.

```ruby
extend :queue, adapter: :rabbitmq
```

Each of these is one line. No migrations, no config files, no boilerplate. Extensions layer on at runtime — no reboot. When you're happy, `export` captures everything.

---

## 7. Go Target

The acquiring company uses Go exclusively. We don't want a long learning curve with the new team.

```bash
$ hecks build --target go
$ cd blog_static_go
$ ./blog serve 9292
```

Same web explorer. Same forms. Same lifecycle badges. Same domain. Single Go binary. The team is productive on day one.

Two languages, one domain. If we're going to work this way, we need to keep apps from breaking when we change the interface. Hecks domains are versioned.

```bash
$ hecks diff
```

> `Removed command: ArchivePost. Added attribute: Post.tags.`

---

## 8. The Real Thing

Blog, comments, photos — this has been done. Let me show you something real.

I tried asking Claude to build a complex app using DDD and hexagonal architecture. If you've tried this, you know it did not go well. Claude doesn't have an opinion. Hecks does. Convention over configuration.

So I asked Claude to build an AI governance platform using Hecks. 5 bounded contexts. 14 aggregates. Cross-domain event flows.

- **Compliance** — governance policies, compliance reviews, exemptions, training records
- **Identity** — stakeholders, audit log
- **Model Registry** — AI models, vendors, data usage agreements
- **Operations** — deployments, incidents, monitoring
- **Risk Assessment** — assessments with findings and mitigations

Create a policy. Activate it — lifecycle badge changes to "active." Suspend it — one click, no form. Reference dropdowns pull from other bounded contexts. The event log shows everything.

The wiring diagram shows how bounded contexts connect through reactive policies.

You can build your own app on top of these domains. The explorer is the proof that it works. Your app uses the same `Post.create`, `Post.publish` API.

---

## 9. Rails

I love Ruby on Rails. This one's for my family.

```bash
$ hecks build --target rails
$ rails server
```

> Hecks on Rails!

You can use Hecks as a drop-in replacement for ActiveRecord. I'm not going into why the active record pattern makes things really hard in Rails. Some of you already understand.

```ruby
class PostsController < ApplicationController
  def create
    Post.create(title: params[:title], body: params[:body])
  end
end
```

```erb
<%= form_with model: @post do |f| %>
  <%= f.text_field :title %>
  <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

Hecks handles the domain and the database. Rails handles the web. No ActiveRecord. Same forms.

Not everyone loves Rails.

```ruby
require "sinatra"
require "blog_domain"

post "/posts" do
  Post.create(title: params[:title], body: params[:body])
  redirect "/posts"
end
```

Same domain. Ten lines. Pick your framework.

---

## 10. Why Not Just AI?

AI is good at writing code. It's bad at maintaining constraints across a codebase over time.

Ask Claude to generate a domain layer and you'll get something that works today. Next week, someone adds a bidirectional reference. The week after, a command gets named "ProcessData." A month later, a value object holds a reference to an aggregate root. None of these are bugs — the code runs fine. They're architectural violations that compound silently until the domain becomes unmaintainable.

Hecks catches all of these at build time. Twelve rules, checked before a single line of code is generated. Every violation comes with a fix suggestion.

Use AI to write the DSL. Use Hecks to guarantee the architecture holds.

---

## 10.5 DSL Parity — 5/5 Parsed, Not Executed

Five source languages live in a Hecks project:

- `.bluebook`   — domain modeling (aggregates, commands, queries, policies)
- `.hecksagon`  — hexagonal architecture wiring (adapters, gates, subscriptions)
- `.fixtures`   — test data + catalog schemas
- `.behaviors`  — behavioral tests
- `.world`      — runtime configuration + strategic descriptors

Every one of them is **parsed**, not evaluated. The Rust runtime parses
directly from text into IR and never sees Ruby. The Ruby loader path
gates every file through an allow-list of DSL keywords before
`Kernel.load` — anything outside the list raises
`Hecksagon::UnsafeHecksagonError` with the offending line.

This matters because the source of truth must be trustworthy. A DSL
that silently accepts arbitrary Ruby is not a DSL — it is a Ruby DSL
*plus* an unrestricted code execution vector. One malicious
`.hecksagon` file, one `system("rm -rf /")`, and the guarantee is gone.

Parity contracts in `spec/parity/` lock each DSL down: Ruby and Rust
must produce byte-equivalent canonical JSON for every shipped file,
or the commit is blocked. Known drift is listed per-file in
`*_known_drift.txt` with a concrete reason and a named fix owner;
every allowed drift is a TODO, not a forever-exception.

---

## 11. Close

Here's what we just did:

- Sketched a domain in a REPL
- Played with live objects
- Built a web explorer with forms, lifecycle badges, and event logs
- Had Claude add a photo gallery and wire shared comments across apps
- Added persistence, multitenancy, Postgres, Slack — one line each
- Generated a Go binary from the same domain
- Generated a Rails app and a Sinatra app
- Showed a 14-aggregate governance platform Claude built in minutes

One DSL. Multiple targets. Zero runtime dependency.

Hecks is a domain compiler. Describe your business once. Generate everything.

```bash
$ gem install hecks
```
