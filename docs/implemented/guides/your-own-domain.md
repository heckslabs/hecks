# Your own domain

[Getting started](getting-started.md) ran a domain that ships in the
repository. This guide is the next step: you write a domain of your own,
run it, and deploy it to AWS Lambda so that something other than Ruby can
call it.

The domain is small on purpose: books on a shelf, lent to one borrower at
a time. Every step is a command you type from the root of a clone of the
repository (the [README](../../../README.md) quickstart gives the clone and
`bundle install`; stay in that `hecks` directory, since `bundle exec` needs it).

Two shell settings come first. hecks records each command it runs in a
journal, which by default lives in a local Postgres. Setting
`HECKS_ENVIRONMENT=memory` keeps that journal in memory, so nothing here
needs a database until you deploy:

```sh
export HECKS_ENVIRONMENT=memory
mkdir -p "$HOME/lending/bluebook/environments"
```

`hecks console` sets this for itself; the other commands below do not.
Skip it and `hecks deploy project` stops with `cannot bind PostgresEra`,
which means hecks went looking for that local Postgres.

## 1. Write it

A domain lives in a directory that is not inside the clone. The
declaration is a `.bluebook` file, named after the domain, inside a
`bluebook` folder. Save this as `$HOME/lending/bluebook/lending.bluebook`:

```ruby bluebook
Hecks.bluebook "Lending" do
  vision "Lend books from a shelf to one borrower at a time."
  supporting

  aggregate "Book" do
    description "A book that is on the shelf or lent to a borrower."

    identified_by :isbn

    attribute :isbn,     Isbn
    attribute :title,    Title
    attribute :borrower, Borrower

    value_object "Isbn" do
      attribute :value, String, pattern: '[^ \t\n\r]'
    end

    value_object "Title" do
      attribute :value, String, pattern: '[^ \t\n\r]'
    end

    value_object "Borrower" do
      attribute :value, String, pattern: '[^ \t\n\r]'
    end

    lifecycle :status, default: "shelved" do
      transition "Lend"   => "lent",    from: "shelved"
      transition "Return" => "shelved", from: "lent"
    end

    command "Shelve" do
      goal "Add a book to the shelf"

      attribute :isbn,  Isbn
      attribute :title, Title

      emits "BookShelved"
    end

    command "Lend" do
      goal "Lend a shelved book to a borrower"

      reference_to Book
      attribute :borrower, Borrower
      sets :borrower

      emits "BookLent"
    end

    command "Return" do
      goal "Take a lent book back"

      reference_to Book

      emits "BookReturned"
    end
  end
end
```

Read it top to bottom; it uses only words you met in Getting started:

- An **aggregate** (`Book`) is the unit that holds state and is changed
  as a whole. `identified_by :isbn` says a book is found by its ISBN.
- A **value object** (`Isbn`, `Title`, `Borrower`) is a typed value with
  no identity of its own. The `pattern` refuses a blank string.
- The **lifecycle** names the states a book can be in and which command
  moves it between them. A command that does not fit the current state is
  refused; you wrote no `if` for that.
- A **command** says what it needs (`attribute`, or `reference_to Book`
  for "an existing book"), what it changes (`sets`) and what it announces
  (`emits`).

Ask hecks to read it back before running anything:

```sh
bundle exec hecks docs "$HOME/lending/bluebook"
```

`hecks docs` prints each command's arguments, the lifecycle, and every
refusal the domain can produce. If you made a mistake in the file, this
is where it is named.

## 2. Run it

Say where the data lives. That is a separate file, because it is a
decision about a deployment and not about the domain. Save this as
`$HOME/lending/bluebook/lending.world`:

```text
Hecks.world "Lending" do
  realm "Guides"
  default_adapter "Postgres"
  default_database "postgres://localhost/lending"

  deployed_to("AwsLambda") do
    region "us-east-1"
    memory 512
    timeout 10
    database "Postgres"
  end
end
```

`default_adapter` binds every aggregate in one line, so this domain needs
no `.hecksagon` file. It names Postgres because that is what runs on
Lambda. To run on your laptop without a database, add an overlay that
swaps the adapter. Save this as
`$HOME/lending/bluebook/environments/memory.world`:

```text
Hecks.world "Lending" do
  default_adapter "Memory"
end
```

`HECKS_ENVIRONMENT=memory` selects that overlay, which is why you exported
it. Now open the domain:

```sh
bundle exec hecks console subject="$HOME/lending"
```

The console lists `Book: lend!, return!, shelve!` and gives you a prompt.
Type:

<!-- doctest:boot
Hecks.hecksagon("Lending") do
  Lending::Book.persisted_by("Memory")
end
-->

```ruby
book = Book.shelve!(isbn: "978-0", title: "Dune")
book.status                        # => "shelved"

book.lend!(borrower: "Ana")
book.status                        # => "lent"
book.borrower.to_h                 # => { value: "Ana" }
```

A book that is already lent cannot be lent again. The refusal comes from
the lifecycle and names the state:

```ruby
book.lend!(borrower: "Ben")        # ~> LifecycleRefused: Lend refused — status is "lent", and Lend moves it only from "shelved"
```

Return it and the shelf is whole again:

```ruby
book.return!
book.status                        # => "shelved"
book.events.map(&:name)            # => ["BookShelved", "BookLent", "BookReturned"]
```

That is the whole loop: change the `.bluebook`, run it, see what it
accepts and refuses. Do this until the rules are the ones you meant,
because the deployed service enforces exactly these.

## 3. Deploy it to Lambda

Lambda runs the domain as a function behind your AWS account's own
sign-in: callers authenticate with AWS credentials (an IAM-signed
request), so there is no password or session of yours to build first.

You need an AWS account with credentials configured, the `aws` and `sam`
command-line tools, `cargo-lambda`, and Rust installed through `rustup`.
The Rust tree in the clone is what gets compiled, so the first build is
slow. If the build reports a missing target, `rustup target add
wasm32-wasip1` adds the WebAssembly one (the build adds the Lambda target
itself).

Turn the domain into a deployable stack. This writes files and touches
nothing in AWS:

```sh
bundle exec hecks deploy project "$HOME/lending" --out="$HOME/lending-deploy"
```

It writes `template.yaml`, `samconfig.toml`, `bastion.yaml` and a
`Makefile`. The stack is named `hecks-lending` and the function
`hecks-lending`, after the domain. Read `template.yaml` before you
deploy. It creates, in your account:

- a private VPC and one RDS Postgres instance (`db.t4g.micro`, 20 GB,
  encrypted, not publicly reachable, its password generated into Secrets
  Manager). Deleting the stack leaves a final database snapshot behind.
- the Lambda function, with an IAM-authenticated Function URL.

The RDS instance is the part that costs money while it exists. Then deploy:

```sh
cd "$HOME/lending-deploy"
export AWS_REGION=us-east-1
make deploy
```

`make deploy` builds the function (`sam build`), checks the compiled rules
against a corpus if you wrote one, creates the stack (`sam deploy`), then
runs `make mint-era`, which opens a short-lived tunnel to the new database
and records the domain's first shape in it. The Makefile contains the
absolute paths of your clone and of `$HOME/lending`, so generate it on the
machine that deploys, and generate it again if either path moves.

### Call it

Any client that can sign an AWS request can call it; the AWS command line
is the shortest. Read the whole state:

```sh
aws lambda invoke --function-name hecks-lending --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"read": true}' out.json && cat out.json
```

Issue a command. `verb` is `<Domain>::<Aggregate>.<Command>`, and `with`
holds the command's facts in the shape `hecks docs` printed:

```sh
aws lambda invoke --function-name hecks-lending --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"verb": "Lending::Book.Shelve", "with": {"isbn": {"value": "978-0"}, "title": {"value": "Dune"}}}' \
  out.json && cat out.json
```

The answer is always a document with `refusals` (empty when the command
was accepted), `events` and `instances`. A refused command still comes
back as a successful call, so read `refusals`. The other languages use the
same payload through their AWS SDK's Lambda `Invoke`.

To remove it, delete the `hecks-lending` stack. Delete the leftover
database snapshot too if you want no residue.

### What was checked

Every Ruby block in this guide runs under
`spec/guides_spec.rb`. The same domain files were also run directly:
`hecks docs`, a scripted boot on Memory and `hecks console subject=` all
worked. `hecks deploy project` wrote the four files above for the Lambda
target, and `sam build` in that directory compiled the domain into the
function (a `bootstrap` binary, `lending.wasm` and `lending.ir.json`).

Not run: `sam deploy`, `make deploy` and the `aws lambda invoke` calls, so the deploy
section is derived from the generated files and from
[Running a rules service](../../running-a-rules-service.md), which is
the full procedure and lists its known gaps. Read those before you rely
on a stack, in particular how the function reads its database password at
start-up (it fetches it from Secrets Manager and the generated template
gives the function no route out of its VPC), and how clients are
authenticated when more than one caller needs different permissions.
