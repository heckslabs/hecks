<p align="center">
  <img src="hecks_logo.png" width="200" height="200" alt="Hecks">
</p>

# Hecks

**In the world of AI, specification is king.**

Hecks is a domain compiler. Describe your business once. Generate complete applications in Ruby, Go, or Rails. Zero runtime dependency. The output is yours.

```bash
$ gem install hecks
```

**[Getting Started — zero to a running domain in 10 minutes](docs/getting_started.md)**

---

## Sketch

Hecks comes with a console for building domains. You sketch, then you play.

```bash
$ hecks new blog
$ cd blog
$ hecks console
```

```ruby
hecks(sketch)> Post
created Post

hecks(sketch)> Post.title String
added attribute title to Post

hecks(sketch)> Post.status String
added attribute status to Post

hecks(sketch)> Post.lifecycle :status, default: "draft"
added lifecycle on status, default: draft

hecks(sketch)> Post.transition "PublishPost" => "published"
added transition PublishPost → published

hecks(sketch)> Post.transition "ArchivePost" => "archived"
added transition ArchivePost → archived

hecks(sketch)> Post.create
created CreatePost

hecks(sketch)> Post.create.title String
added attribute title to CreatePost → CreatedPost
```

Blogs need comments.

```ruby
hecks(sketch)> Comment
created Comment

hecks(sketch)> Comment.post_id reference_to("Post")
added reference post_id → Post

hecks(sketch)> Comment.author String
added attribute author to Comment

hecks(sketch)> Comment.body String
added attribute body to Comment

hecks(sketch)> Comment.create
created CreateComment

hecks(sketch)> Comment.create.post_id reference_to("Post")
added reference post_id → Post

hecks(sketch)> Comment.create.author String
added attribute author to CreateComment

hecks(sketch)> Comment.create.body String
added attribute body to CreateComment → CreatedComment
```

## Play

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

> Wrote `hecks_domain.rb` -- the source of truth. Everything generates from this.

## The Web Explorer

```ruby
hecks(play)> serve!
```

> `Serving BlogDomain on http://localhost:9292`

Open the browser. Create a post. Watch the lifecycle badge change from "draft" to "published." Add a comment -- the Post dropdown shows your posts. Check the event log.

These are domain events, not framework events. `CreatedPost`. `PublishedPost`. `CreatedComment`. This is your ubiquitous language.

## Let Claude Drive

Hecks is AI-native. It ships with an MCP server so Claude can model domains alongside you.

```bash
$ hecks mcp
```

> "Build me a photo gallery. Photos have a title, url, taken_at date, and tags."

Claude generates the domain. Every operation shows its result.

> "Promote Comments into its own domain. Wire it into both Blog and Photos."

Claude promotes the aggregate, creates the new domain file, wires both consumers.

> "When I upload a photo, create a draft blog post automatically."

Claude adds one policy:

```ruby
policy "AutoDraft" do
  on "UploadedPhoto"
  trigger "CreateDraftPost"
  map title: :title
end
```

One policy. Three domains talking through events. Upload a photo, a draft post appears. The event log shows the chain: `UploadedPhoto -> AutoDraft -> CreatedDraftPost`.

## Extend

Everything so far is in memory. Fix that with one word.

```ruby
extend :sqlite
```

Oops, we need multitenancy.

```ruby
extend :tenancy
```

Oops, it's selling like hotcakes. Real database.

```ruby
extend :postgres
```

Slack notifications for the dev team.

```ruby
extend :slack, webhook: ENV["SLACK_URL"]
```

The company got acquired. They need our events in real time.

```ruby
extend :queue, adapter: :rabbitmq
```

Each one is one line. No migrations, no config files. Extensions layer on at runtime -- no reboot. When you're happy, `export` captures everything.

## Go

The acquiring company uses Go exclusively. We don't want a long learning curve.

```bash
$ hecks build --target go
$ ./blog serve 9292
```

Same web explorer. Same forms. Same lifecycle badges. Single Go binary. The team is productive on day one.

Two languages, one domain. Hecks domains are versioned so apps don't break when the interface changes.

```bash
$ hecks diff
```

> `Removed command: ArchivePost. Added attribute: Post.tags.`

## Rails

This one's for my family.

```bash
$ hecks build --target rails
$ rails server
```

> Hecks on Rails!

You can use Hecks as a drop-in replacement for ActiveRecord.

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

## The Real Thing

Blog, comments, photos -- this has been done. Here's something real.

I tried asking Claude to build a complex app using DDD and hexagonal architecture. If you've tried this, you know it did not go well. **Claude doesn't have an opinion. Hecks does.** Convention over configuration.

I asked Claude to build an AI governance platform using Hecks. 5 bounded contexts. 14 aggregates. Cross-domain event flows:

| Domain | Aggregates |
|--------|-----------|
| **Compliance** | Governance Policies, Compliance Reviews, Exemptions, Training Records |
| **Identity** | Stakeholders, Audit Log |
| **Model Registry** | AI Models, Vendors, Data Usage Agreements |
| **Operations** | Deployments, Incidents, Monitoring |
| **Risk Assessment** | Assessments with Findings and Mitigations |

Lifecycle badges. Reference dropdowns across bounded contexts. Direct-action buttons. Event log. Wiring diagram showing how contexts connect through reactive policies.

The explorer is the proof that the domain works. Your app uses the same `Post.create`, `Post.publish` API.

## The DSL

Everything above generates from a single Ruby file:

```ruby
Hecks.domain "Banking" do
  aggregate "Account" do
    attribute :balance, Float
    attribute :status, String, default: "open"
    attribute :ledger, list_of("LedgerEntry")

    entity "LedgerEntry" do
      attribute :amount, Float
      attribute :description, String
    end

    command "Deposit" do
      attribute :account_id, String
      attribute :amount, Float
    end

    lifecycle :status, default: "open" do
      transition "CloseAccount" => "closed"
    end

    validation :balance, presence: true
    invariant("balance must not be negative") { balance >= 0 }
    specification("LargeWithdrawal") { |w| w.amount > 10_000 }
    query("ByCustomer") { |cid| where(customer_id: cid) }

    port :teller do
      allow :find, :all, :deposit
    end
  end

  policy "DisburseFunds" do
    on "IssuedLoan"
    trigger "Deposit"
    map account_id: :account_id, principal: :amount
  end
end
```

| Concept | Purpose |
|---------|---------|
| **Aggregates** | Business objects with typed attributes and commands |
| **Value Objects** | Frozen, immutable details embedded in an aggregate |
| **Entities** | Mutable sub-objects with their own identity |
| **Commands** | Become class methods and auto-generate domain events |
| **Lifecycles** | State machines with transition guards |
| **Validations** | Checked at creation time |
| **Invariants** | Enforced on aggregate state after every change |
| **Specifications** | Reusable, composable predicates |
| **Policies** | React to events by triggering commands |
| **Queries & Scopes** | Named, chainable query objects |
| **Services** | Orchestrate multiple commands across aggregates |
| **Ports** | Role-based access control boundaries |

## Build-Time Validation

Hecks validates your domain before generating anything. Every error includes a fix suggestion.

| Rule | What it checks |
|------|---------------|
| CommandNaming | Commands start with a verb |
| NoBidirectionalReferences | No circular A->B and B->A references |
| NoSelfReferences | Aggregates don't reference themselves |
| ValidReferences | References point to existing aggregates |
| NoImplicitForeignKeys | Warns when `_id String` should be `reference_to` |
| + 7 more | Name collisions, reserved words, policy wiring, structure |

## Data Contracts

Eight contracts guarantee Ruby and Go generate identical behavior:

| Contract | Governs |
|----------|---------|
| `AggregateContract` | Validations, enums, lifecycle, self-ref detection |
| `DisplayContract` | Cell rendering, lifecycle transitions, summaries |
| `FormParsingContract` | Type coercion for form submissions |
| `UILabelContract` | PascalCase splitting, pluralization |
| `EventLogContract` | `/_events` JSON shape |
| `ViewContract` | Template structs, short ID display |
| `TypeContract` | Type mapping across Ruby, Go, SQL, JSON |
| `EventContract` | Event interface, required fields |

No inline code generation. Every display convention is a named method on a contract.

## Why Not Just AI?

AI is good at writing code. It's bad at maintaining constraints across a codebase over time.

Ask Claude to generate a domain layer and you'll get something that works today. Next week, someone adds a bidirectional reference. The week after, a command gets named "ProcessData." A month later, a value object holds a reference to an aggregate root. None of these are bugs -- the code runs fine. They're architectural violations that compound silently.

Hecks catches all of these at build time. Twelve rules, checked before a single line of code is generated. The generated output has typed ports, event-driven policies, and bounded context boundaries that can't be bypassed.

Use AI to write the DSL. Use Hecks to guarantee the architecture holds.

---

```bash
$ gem install hecks
```

[Getting Started](docs/getting_started.md) | [All Features](FEATURES.md) | [Into the Weeds](INTO_THE_WEEDS.md) | [DDD Mapping](hecks_docs/ddd.md) | [Hexagonal Architecture](hecks_docs/hexagonal.md) | [Why Hecks](hecks_docs/why_hecks.md) | [Architecture Decisions](docs/usage/architecture_decisions.md)

## License

MIT
