require "spec_helper"
require "socket"
require "json"
require "openssl"
require_relative "../../../lib/hecks/hecks/adapters/host_http"

# The HostHttp port's adapter runs the signed-webhook checks against a service, with the signing
# secret taken from the environment and never from a command argument.
RSpec.describe Hecks::Adapters::HostHttp do
  let(:adapter) { described_class.new }

  it "refuses without a signing secret in the environment" do
    stub_const("ENV", ENV.to_h.merge("SMOKE_WEBHOOK_SECRET" => nil))

    expect { adapter.probe(path: { value: "/hook" }) }
      .to raise_error(ArgumentError, /SMOKE_WEBHOOK_SECRET/)
  end

  it "refuses a scheme it cannot sign with" do
    stub_const("ENV", ENV.to_h.merge("SMOKE_WEBHOOK_SECRET" => "s"))

    expect { adapter.probe(path: { value: "/hook" }, scheme: { value: "md5" }) }
      .to raise_error(ArgumentError, /unknown scheme/)
  end

  it "reads the request body from a payload file", :io do
    stub_const("ENV", ENV.to_h.merge("SMOKE_WEBHOOK_SECRET" => "s"))
    server = TCPServer.new("127.0.0.1", 0)
    seen = []
    thread = Thread.new do
      loop do
        client = server.accept
        head = client.gets("\r\n\r\n")
        length = head[/Content-Length: (\d+)/i, 1].to_i
        seen << client.read(length) if length.positive?
        client.write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    end
    file = File.join(Dir.tmpdir, "hecks-hook-payload-#{Process.pid}.json")
    File.write(file, %({"kind":"from-file"}))

    expect do
      adapter.probe(url: { value: "http://127.0.0.1:#{server.addr[1]}" }, path: { value: "/hook" },
                    payload_file: { value: file })
    end.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /FAILED/)
    expect(seen).to include(%({"kind":"from-file"}))
  ensure
    thread&.kill
    server&.close
    File.delete(file) if file && File.exist?(file)
  end

  describe "#fetch" do
    # A stub host answering every request with a `/version` document.
    def serve(era:, version: "3.0.0")
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          client = server.accept
          while (line = client.gets) && line != "\r\n"; end
          body = JSON.generate(era: era, version: version)
          client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          client.close
        end
      end
      yield "http://127.0.0.1:#{server.addr[1]}"
    ensure
      thread&.kill
      server&.close
    end

    def eras(text)
      file = File.join(Dir.tmpdir, "hecks-eras-#{Process.pid}-#{rand(1_000_000)}.txt")
      File.write(file, text)
      yield file
    ensure
      File.delete(file) if file && File.exist?(file)
    end

    it "answers the era and version a host reports, with the verdict on a listed era", :io do
      serve(era: "abc123") do |url|
        eras("# eras\nabc123\n") do |file|
          answer = adapter.fetch(host: { value: url }, expected: { value: file })

          expect(answer.transform_values { |field| field[:value] }).to eq(
            era: "abc123", version: "3.0.0", verdict: "match", report: "era abc123 is expected (abc123)"
          )
        end
      end
    end

    it "answers a mismatch instead of refusing it, so the record keeps what the host reported", :io do
      serve(era: "abc123") do |url|
        eras("def456\n") do |file|
          answer = adapter.fetch(host: { value: url }, expected: { value: file }, timeout: { value: 2.0 })

          expect(answer.dig(:verdict, :value)).to eq("mismatch")
          expect(answer.dig(:era, :value)).to eq("abc123")
        end
      end
    end

    it "answers unlisted when the file names no era", :io do
      serve(era: "abc123") do |url|
        eras("# none\n") do |file|
          expect(adapter.fetch(host: { value: url }, expected: { value: file }).dig(:verdict, :value))
            .to eq("unlisted")
        end
      end
    end

    it "refuses a host that cannot be reached" do
      eras("abc123\n") do |file|
        expect { adapter.fetch(host: { value: "http://127.0.0.1:1" }, expected: { value: file }) }
          .to raise_error(Hecks::Runtime::EraCheck::ExpectedEra::Unreachable, /could not be reached/)
      end
    end

    it "refuses an allow-list file that is not there" do
      expect { adapter.fetch(host: { value: "http://127.0.0.1:1" }, expected: { value: "/no/such/eras" }) }
        .to raise_error(Errno::ENOENT)
    end

    it "refuses when no file was named" do
      expect { adapter.fetch(host: { value: "http://127.0.0.1:1" }) }.to raise_error(ArgumentError, /allow-list/)
    end
  end
end
