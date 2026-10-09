module Hecks
  module CLI
    class SmokeHttp
      # The signed-webhook checks a run makes, each reported ok or failed.
      module Checks
        private

        def check(label)
          @out.print "  #{label}... "
          yield
          @out.puts "ok"
        rescue StandardError => e
          @out.puts "FAILED: #{e.message}"
          @failures << label
        end

        def check_health
          return unless @settings[:health_path]

          check("GET #{@settings[:health_path]} answers 200") { expect_status(get(@settings[:health_path]), 200) }
        end

        def check_unsigned
          check("a delivery with no signature is refused") { expect_refused(post(payload, {})) }
        end

        def check_wrong_secret
          check("a delivery signed with the wrong secret is refused") do
            expect_refused(post(payload, signature_header("not-the-secret-#{run_id}", payload)))
          end
        end

        # A trailing space is enough: the signature covers the exact bytes.
        def check_tampered_body
          check("a delivery whose body changed after signing is refused") do
            expect_refused(post("#{payload} ", signature_header(@settings.fetch(:secret), payload)))
          end
        end

        def check_signed
          check("a correctly signed delivery is accepted") { expect_success(post(payload, signed_headers)) }
        end

        def check_repeat
          check("a repeated delivery of the same payload is accepted again, not an error") do
            before = state
            expect_success(post(payload, signed_headers))
            after = state
            unless before == after
              raise Failure,
                    "the state changed on a repeated delivery:\n    before #{before}\n    after  #{after}"
            end
          end
        end

        def summarize
          if @failures.empty?
            @out.puts "\nSMOKE HTTP PASSED"
            0
          else
            @out.puts "\nSMOKE HTTP FAILED (#{@failures.size}):"
            @failures.each { |label| @out.puts "  - #{label}" }
            1
          end
        end
      end
    end
  end
end
