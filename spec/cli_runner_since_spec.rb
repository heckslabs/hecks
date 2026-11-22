require "spec_helper"

# `--since[=<hash>]` lets a caller that asks a query again pay for a line when nothing changed.
RSpec.describe Hecks::Adapters::Driving::CliRunner::Since, :aggregate_failures do
  subject(:since) { Object.new.extend(described_class) }

  describe "#split_since" do
    it "takes the bare flag out of a line" do
      flag, rest = since.split_since(%w[Workspace.status --since])

      expect(flag).to eq(given: true, hash: nil)
      expect(rest).to eq(%w[Workspace.status])
    end

    it "takes the flag with a hash out of a line" do
      flag, rest = since.split_since(%w[--since=ab12 Workspace.status path=x])

      expect(flag).to eq(given: true, hash: "ab12")
      expect(rest).to eq(%w[Workspace.status path=x])
    end

    it "leaves a line without it alone, and a query's own `since` argument" do
      flag, rest = since.split_since(%w[Board.log since=2026-11-21])

      expect(flag).to eq(given: false, hash: nil)
      expect(rest).to eq(%w[Board.log since=2026-11-21])
    end
  end

  describe "#answer_since" do
    let(:text) { "board 2026-11-21T10:00:00Z\n3 ahead" }

    it "ends the answer with its hash when asked bare" do
      out, status = since.answer_since([text, 0], { given: true, hash: nil })

      expect(out).to eq("#{text}\n[since: #{since.digest_of(text)}]")
      expect(status).to eq(0)
    end

    it "answers one line when the hash matches, though the clock moved" do
      digest = since.digest_of(text)
      later = text.sub("10:00:00", "10:07:31")

      expect(since.answer_since([later, 0], { given: true, hash: digest })).to eq(["unchanged since #{digest}", 0])
    end

    it "answers in full, with the new hash, when something changed" do
      out, = since.answer_since(["board\n4 ahead", 0], { given: true, hash: since.digest_of(text) })

      expect(out).to start_with("board\n4 ahead\n[since: ")
    end

    it "keeps a refusal's status" do
      expect(since.answer_since(["no", 1], { given: true, hash: nil }).last).to eq(1)
    end
  end
end
