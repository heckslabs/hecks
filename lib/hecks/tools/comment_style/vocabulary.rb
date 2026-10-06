# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    # The word lists the comment linters read: which capitalised tokens are correct as written.
    module CommentStyle
      # Initialisms and keywords that are correctly written in capitals.
      ACRONYMS = %w[
        ARGV ARN AZ ECR ES FSM GVL IAM IGW IPC IRB LLM MB MVCC NAT OOM RDS SG SIGKILL SIGTERM STDIO TOML
        UI VCS VM VPC WASI
        ABC ACID ADR API ASC ASCII AST AWS BFS BYPASSRLS CAS CDN CEO CI CLI CPU CRUD CSRF CSS CSV CTE DB DBA DDD DDL
        DELETE DESC DFS DML DNS DSL ENV ERB ERD FIFO FIXME FK FQN GC GET GIN HMAC HTML HTTP HTTPS ID INSERT IO IR ISO
        JS JSON JSONB JSONL JWKS JWT LIFO LRU MCP MDN MRI MVP NAMEDATALEN NIL NULL OIDC OK ORM OS
        PATCH PG PID PK PM POSIX POST PR PRAGMA PRD PUT QA QC RAM RBAC README REPL REST RLS RNG RPC RUBYOPT
        SAM SAVEPOINT SDK SELECT SHA SME SQL SSH SSL SSM SW STDERR STDIN STDOUT TCP TLA TLS TOCTOU TODO TTL UID UL
        URI URL UTC UTF UUID VO WASM XML YAML
        ACL ALB BC GNU OAC WAF
        CLOUDFRONT ECS HSM KMS
      ].to_set.freeze

      # Names whose correct spelling is neither all-caps nor all-lowercase.
      PROPER_NOUNS = {
        "CLOUDFLARE" => "Cloudflare", "OAUTH" => "OAuth", "RSPEC" => "RSpec", "JAVASCRIPT" => "JavaScript",
        "GITHUB" => "GitHub", "GOOGLE" => "Google", "GRAPHVIZ" => "Graphviz", "HECKS" => "Hecks",
        "POSTGRES" => "Postgres", "POSTGRESQL" => "PostgreSQL", "PUMA" => "Puma", "RAILS" => "Rails",
        "RUBY" => "Ruby", "RUST" => "Rust", "SQLITE" => "SQLite"
      }.freeze

      # SQL keywords that are rarely English emphasis. Kept in capitals on a line
      # that reads as SQL, and always kept in a file that talks to a database.
      SQL_STRONG = %w[
        ALTER ATTACH BEGIN CASCADE COMMIT CONCURRENTLY DETACH DISTINCT FORCE GRANT LIMIT MATERIALIZED
        NULLS OFFSET PARTITION RETURNING REVOKE ROLLBACK SERIALIZABLE VACUUM
      ].to_set.freeze

      # SQL keywords that are also everyday emphasis targets (`FROM`, `FIRST`, `SET`).
      SQL_WEAK = %w[
        COLUMN CONSTRAINT CREATE DEFAULT DROP EXCLUSIVE EXISTS FIRST FROM INDEX JOIN LAST LOCK LOGIN
        NOBYPASSRLS NOCREATEDB NOCREATEROLE NOLOGIN NOSUPERUSER OWNER POLICY
        REFERENCES ROLE SCHEMA SET SHARE TABLE TRANSACTION TRIGGER UNION UNIQUE UPDATE VALUES VIEW WHERE
      ].to_set.freeze

      SQL_NEUTRAL = %w[ALL AND AS BY FOR IN IS NOT OF ON OR TO].to_set.freeze

      SQL_PATH = %r{sql|postgres|/d1|_era|/era|lineage|outbox|schema|persistence}

      SELF_EVIDENT = %w[
        to_s to_str to_sym to_h to_a to_proc inspect hash eql? == === <=> method_missing
        respond_to_missing? pretty_print
      ].to_set.freeze
    end
  end
end
