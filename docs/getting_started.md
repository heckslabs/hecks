# Getting Started with Hecks

> **Note:** The `hecks` gem is not yet published to RubyGems. Install from source instead:
> ```bash
> git clone https://github.com/hecks-rb/hecks.git
> cd hecks
> bundle install
> ```
> Then use `bundle exec ruby -Ilib` in place of `ruby` in the examples below.

From zero to a running domain in 10 minutes.

Hecks is a domain compiler. You describe your business in a single Ruby DSL file — the Bluebook — and Hecks builds everything: typed aggregates, commands that emit events, lifecycle state machines, queries, and a web explorer. You own the output.

This guide walks through a **Bookshelf** domain: books with a checkout lifecycle, loans that reference books, and a running web explorer.

---

## Prerequisites

- Ruby 3.1 or later
- Bundler (`gem install bundler`)

---

## Step 1 — Install

```bash
$ gem install hecks
```

---

## Step 2 — Create a project

```bash
$ hecks new bookshelf
```

```
Created bookshelf/BookshelfBluebook
Created bookshelf/app.rb
Created bookshelf/Gemfile
Created bookshelf/spec/spec_helper.rb
Created bookshelf/.gitignore
Created bookshelf/.rspec
Created bookshelf/
  BookshelfBluebook
  app.rb
  Gemfile
  spec/spec_helper.rb
  .gitignore
  .rspec

Get started:
  cd bookshelf
  bundle install
  ruby app.rb
```

```bash
$ cd bookshelf
$ bundle install
```

`Hecks.boot(__dir__)` finds `BookshelfBluebook`, validates it, builds the gem in memory, and returns a `Runtime`. One call.

---

## Step 3 — Define the domain

Replace `BookshelfBluebook` with:

```ruby
Hecks.domain "Bookshelf" do
  aggregate "Book" do
    attribute :title,  String
    attribute :author, String
    attribute :status, String, default: "available" do
      transition "CheckOutBook" => "checked_out"
      transition "ReturnBook"   => "available"
    end

    validation :title,  presence: true
    validation :author, presence: true

    command "AddBook" do
      attribute :title,  String
      attribute :author, String
    end

    command "CheckOutBook" do
      reference_to "Book"
    end

    command "ReturnBook" do
      reference_to "Book"
    end

    query "Available" do
      where(status: "available")
    end

    query "ByAuthor" do |author|
      where(author: author)
    end
  end
end
```

**What this declares:**

| Element | What it does |
|---------|-------------|
| `attribute :status, String, default: "available" do` | Status field with a default |
| `transition "CheckOutBook" => "checked_out"` | Lifecycle: this command moves status to `checked_out` |
| `command "AddBook"` | Becomes `Book.add(...)` — emits `AddedBook` |
| `command "CheckOutBook"` | Becomes `Book.check_out(...)` — emits `CheckedOutBook` |
| `query "Available"` | Becomes `Book.available` — returns all with `status: "available"` |
| `query "ByAuthor"` | Becomes `Book.by_author("name")` |

---

## Step 4 — Build and run

```bash
$ ruby app.rb
```

Edit `app.rb` to use the domain:

```ruby
require "hecks"

app = Hecks.boot(__dir__)

app.on("AddedBook") { |e| puts "  [event] AddedBook: #{e.title} by #{e.author}" }

moby   = Book.add(title: "Moby-Dick",       author: "Herman Melville")
gatsby = Book.add(title: "The Great Gatsby", author: "F. Scott Fitzgerald")
dune   = Book.add(title: "Dune",            author: "Frank Herbert")

puts "Total books: #{Book.count}"
Book.all.each { |b| puts "  #{b.title} — #{b.status}" }
```

Output:

```
  [event] AddedBook: Moby-Dick by Herman Melville
  [event] AddedBook: The Great Gatsby by F. Scott Fitzgerald
  [event] AddedBook: Dune by Frank Herbert
Total books: 3
  Moby-Dick — available
  The Great Gatsby — available
  Dune — available
```

---

## Step 5 — Open the console

```bash
$ hecks console bookshelf
```

```
hecks(sketch)> Book
created Book

hecks(sketch)> Book.isbn String
added attribute isbn to Book

hecks(sketch)> Book.published_year Integer
added attribute published_year to Book
```

The console edits `BookshelfBluebook` live. Every change is written back to the file.

---

## Step 6 — Play mode

Still inside `hecks console`:

```ruby
hecks(sketch)> play!
```

```
Entering play mode (1 aggregate, 3 commands)
```

```ruby
hecks(play)> Book.add(title: "Dune", author: "Frank Herbert")
```

```
AddedBook { title: "Dune", author: "Frank Herbert", status: "available" }
```

```ruby
hecks(play)> Book.check_out(book: Book.all.first.id)
```

```
CheckedOutBook { status: "checked_out" }
```

```ruby
hecks(play)> Book.all
```

```
[#<Book title="Dune" status="checked_out">]
```

---

## Step 7 — Add the checkout lifecycle

The `CheckOutBook` and `ReturnBook` transitions on `status` enforce the state machine at runtime. Try checking out an already-checked-out book — Hecks raises `Hecks::TransitionNotAllowed`.

Add this to `app.rb` to see it in action:

```ruby
Book.check_out(book: moby.id)
moby = Book.find(moby.id)
puts "Moby-Dick: #{moby.status}"   # => checked_out

Book.return(book: moby.id)
moby = Book.find(moby.id)
puts "Moby-Dick: #{moby.status}"   # => available
```

Output:

```
  [event] CheckedOutBook: status=checked_out
  [event] ReturnedBook: status=available
Moby-Dick: checked_out
Moby-Dick: available
```

State predicates are generated automatically:

```ruby
moby.available?    # => true
moby.checked_out?  # => false
```

---

## Step 8 — Add a second aggregate

Loans track who has a book and when it's due. Add this to `BookshelfBluebook` inside the `Hecks.domain` block:

```ruby
  aggregate "Loan" do
    reference_to "Book"
    attribute :borrower_name, String
    attribute :due_date,      String
    attribute :status,        String, default: "active" do
      transition "CloseLoan" => "returned"
    end

    validation :borrower_name, presence: true
    validation :due_date,      presence: true

    command "CreateLoan" do
      reference_to "Book"
      attribute :borrower_name, String
      attribute :due_date,      String
    end

    command "CloseLoan" do
      reference_to "Loan"
    end

    query "Active" do
      where(status: "active")
    end
  end
```

`reference_to "Book"` at the aggregate level means Loan holds a `book` foreign key. The web explorer renders it as a dropdown showing available books.

Now use it:

```ruby
Book.check_out(book: moby.id)
loan = Loan.create(book: moby.id, borrower_name: "Alice", due_date: "2026-04-15")
puts "Active loans: #{Loan.active.count}"

# Return the book and close the loan
Book.return(book: moby.id)
Loan.close(loan: loan.id)
puts "Active loans: #{Loan.active.count}"
```

Output:

```
  [event] CheckedOutBook: status=checked_out
  [event] CreatedLoan: borrower=Alice, due=2026-04-15
Active loans: 1
  [event] ReturnedBook: status=available
  [event] ClosedLoan: status=returned
Active loans: 0
```

---

## Step 9 — Web explorer

```bash
$ hecks serve bookshelf
```

```
Serving BookshelfDomain on http://localhost:9292
```

Open `http://localhost:9292`:

- **Book** — a form with title and author fields. Status shows as a lifecycle badge: `available` / `checked_out`. Transition buttons appear inline.
- **Loan** — the Book field is a dropdown showing all books. Status badge and CloseLoan button.
- **Event log** at `/_events` — every `AddedBook`, `CheckedOutBook`, `CreatedLoan` in order.

No routes to write. No views to build. The explorer generates from the Bluebook.

---

## Step 10 — Next steps

You have a running domain. Here's where to go from here:

| Topic | Link |
|-------|------|
| Full DSL reference | [docs/usage/dsl_reference.md](usage/dsl_reference.md) |
| Generate Ruby static gem | `hecks build --target ruby` |
| Generate Go binary | `hecks build --target go` |
| Generate Rails app | `hecks build --target rails` |
| Persist with SQLite | [docs/usage/sql_adapter.md](usage/sql_adapter.md) |
| Persist with MongoDB | [docs/usage/mongodb_adapter.md](usage/mongodb_adapter.md) |
| Rails integration | [docs/usage/hecks_on_rails.md](usage/hecks_on_rails.md) |
| Multi-domain wiring | [docs/usage/connections.md](usage/connections.md) |
| MCP server (Claude) | `hecks mcp` |
| Interactive console | `hecks console bookshelf` |

The finished bookshelf example — with both aggregates, all commands, and a runnable script — lives at [`examples/bookshelf/`](../examples/bookshelf/).

```bash
# Run the complete example from the Hecks project root:
$ ruby -Ilib examples/bookshelf/app.rb
```
