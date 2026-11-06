require "hecks"
require "json"
require_relative "../../lib/hecks/hecks/adapters/github_pull_requests"

# Transport only: the runner is a recorder, so the suite never shells out to a real `gh`. The `gh`
# arguments and the answers are read for real.
RSpec.describe Hecks::Adapters::GithubPullRequests do
  subject(:pulls) { described_class.new(runner: runner) }

  let(:calls) { [] }
  let(:replies) { {} }
  let(:runner) do
    lambda do |args|
      calls << args
      replies.fetch(args) { ["", "no reply for #{args.inspect}", false] }
    end
  end

  def created = ["pr", "create", "--head", "feature", "--base", "main", "--fill"]

  describe "#create" do
    it "opens the pull request and answers its number and URL", :aggregate_failures do
      replies[created] = ["Creating pull request\nhttps://github.com/acme/app/pull/42\n", "", true]

      answer = pulls.create(branch: { value: "feature" }, base: { value: "main" })

      expect(answer[:outcome]).to eq(value: "opened")
      expect(answer[:number]).to eq(value: "42")
      expect(answer[:url]).to eq(value: "https://github.com/acme/app/pull/42")
    end

    it "defaults the base to main" do
      replies[created] = ["https://github.com/acme/app/pull/42\n", "", true]

      pulls.create(branch: { value: "feature" })

      expect(calls).to include(created)
    end

    it "refuses when no branch is named" do
      expect { pulls.create(base: { value: "main" }) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no branch/)
    end

    it "refuses with what gh said when it refuses" do
      replies[created] = ["", "a pull request for branch \"feature\" already exists", false]

      expect { pulls.create(branch: { value: "feature" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /already exists/)
    end
  end

  describe "#squash" do
    it "squash-merges the pull request by its number, and never passes --admin", :aggregate_failures do
      replies[["pr", "merge", "42", "--squash"]] = ["", "", true]

      expect(pulls.squash(number: { value: "42" })).to include(outcome: { value: "merged" })
      expect(calls).to eq([["pr", "merge", "42", "--squash"]])
    end

    it "refuses when no number is named" do
      expect { pulls.squash(number: nil) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no pull request number/)
    end

    it "refuses a number that gh would read as an option", :aggregate_failures do
      expect { pulls.squash(number: { value: "--admin" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not a number/)
      expect(calls).to be_empty
    end

    it "refuses with what gh said when GitHub will not merge" do
      replies[["pr", "merge", "42", "--squash"]] = ["", "Pull request #42 is not mergeable", false]

      expect { pulls.squash(number: { value: "42" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not mergeable/)
    end
  end

  describe "#status" do
    let(:view) do
      { "number" => 42, "state" => "OPEN", "url" => "https://github.com/acme/app/pull/42", "mergedAt" => nil,
        "statusCheckRollup" => [{ "name" => "rspec", "conclusion" => "SUCCESS" },
                                { "name" => "lint", "conclusion" => "", "state" => "PENDING" }] }
    end

    it "answers the state, URL, merge and checks as text" do
      replies[["pr", "view", "42", "--json", "number,state,url,mergedAt,statusCheckRollup"]] = [JSON.generate(view), "", true]

      expect(pulls.status(number: { value: "42" })[:text]).to eq(
        "number: 42\nstate: OPEN\nurl: https://github.com/acme/app/pull/42\nmerged: no\nchecks: rspec=SUCCESS, lint=PENDING\n"
      )
    end
  end

  describe "#amend" do
    def view_args = ["pr", "view", "42", "--json", "state"]

    def state_reply(state)
      replies[view_args] = [JSON.generate("state" => state), "", true]
    end

    def edit_title(title: nil, body: nil)
      pulls.amend(number: { value: "42" }, title: title && { value: title }, body: body && { value: body })
    end

    it "edits the title and body of an open pull request, each as one argv element", :aggregate_failures do
      state_reply("OPEN")
      replies[["pr", "edit", "42", "--title=New title", "--body=- a line\n--flag"]] = ["", "", true]

      answer = edit_title(title: "New title", body: "- a line\n--flag")

      expect(answer[:outcome]).to eq(value: "edited")
      expect(calls.last).to eq(["pr", "edit", "42", "--title=New title", "--body=- a line\n--flag"])
    end

    it "edits only the body when no title is named" do
      state_reply("OPEN")
      replies[["pr", "edit", "42", "--body=Only the body"]] = ["", "", true]

      edit_title(body: "Only the body")

      expect(calls.last).to eq(["pr", "edit", "42", "--body=Only the body"])
    end

    it "never passes a branch, a base, a merge or a close to gh", :aggregate_failures do
      state_reply("OPEN")
      replies[["pr", "edit", "42", "--title=T"]] = ["", "", true]

      edit_title(title: "T")

      expect(calls.flatten).not_to include("--base", "--head", "merge", "close", "--admin")
    end

    it "refuses when neither a title nor a body is named", :aggregate_failures do
      expect { edit_title }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no title or body/)
      expect(calls).to be_empty
    end

    it "refuses a blank title and body as not named" do
      expect { edit_title(title: "  ", body: "") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no title or body/)
    end

    it "refuses a pull request that is not open, and edits nothing", :aggregate_failures do
      state_reply("MERGED")

      expect { edit_title(title: "T") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not open \(MERGED\)/)
      expect(calls).to eq([view_args])
    end

    it "refuses a number that gh would read as an option" do
      expect { pulls.amend(number: { value: "--admin" }, title: { value: "T" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not a number/)
    end

    it "refuses with what gh said when GitHub refuses the edit" do
      state_reply("OPEN")
      replies[["pr", "edit", "42", "--title=T"]] = ["", "could not edit", false]

      expect { edit_title(title: "T") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /could not edit/)
    end
  end

  describe "#timeline" do
    def timeline_call = ["api", "repos/{owner}/{repo}/issues/42/timeline", "--paginate", "--slurp"]

    def raw_rows
      [{ kind: "commented", actor: "bot", at: "2026-11-05T16:00:00Z" },
       { kind: "review_requested", actor: "chris", at: "2026-11-05T16:10:00Z" },
       { kind: "auto_merge_enabled", actor: "chris", at: "2026-11-05T16:20:00Z" },
       { kind: "labeled", actor: "bot", at: "2026-11-05T16:25:00Z" },
       { kind: "merged", actor: "gh-merger", at: "2026-11-05T16:35:49Z" }]
    end

    let(:page) do
      [
        { "event" => "commented", "actor" => { "login" => "bot" }, "created_at" => "2026-11-05T16:00:00Z" },
        { "event" => "review_requested", "actor" => { "login" => "chris" }, "created_at" => "2026-11-05T16:10:00Z" },
        { "event" => "auto_merge_enabled", "actor" => { "login" => "chris" }, "created_at" => "2026-11-05T16:20:00Z" },
        { "event" => "labeled", "actor" => { "login" => "bot" }, "created_at" => "2026-11-05T16:25:00Z" },
        { "event" => "merged", "actor" => { "login" => "gh-merger" }, "created_at" => "2026-11-05T16:35:49Z" }
      ]
    end

    before do
      replies[["pr", "view", "42", "--json", "number"]] = ["{\"number\":42}\n", "", true]
      replies[timeline_call] = [JSON.generate([page]), "", true]
    end

    it "answers every timeline entry as a raw row, with its actor and time, oldest first, leaving the kinds to the where" do
      expect(pulls.timeline(number: { value: "42" })).to eq(raw_rows)
    end

    it "makes only read calls, never a write", :aggregate_failures do
      pulls.timeline(number: { value: "42" })

      expect(calls).to eq([["pr", "view", "42", "--json", "number"], timeline_call])
      expect(calls.flatten.join(" ")).not_to match(/merge|edit|close|reopen|--admin|-X|POST|PATCH|PUT|DELETE/)
    end

    it "refuses a number that is not a pull request, and reads no timeline", :aggregate_failures do
      replies[["pr", "view", "7", "--json", "number"]] = ["", "no pull requests found with number 7", false]

      expect { pulls.timeline(number: { value: "7" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no pull requests found/)
      expect(calls).to eq([["pr", "view", "7", "--json", "number"]])
    end

    it "refuses a number that gh would read as an option", :aggregate_failures do
      expect { pulls.timeline(number: { value: "--admin" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not a number/)
      expect(calls).to be_empty
    end
  end
end
