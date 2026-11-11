# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "digest"
require "json"
require "time"

module ZeroXDA
  module TradingLab
    # PostgreSQL history of the lab's research: simulation runs, the paper portfolio each
    # ended with, and the experiment a run belongs to. It holds paper results only; there is
    # no balance, order or credential in it.
    #
    # The store is optional. Without TRADING_LAB_DATABASE_URL the service computes exactly as
    # before and keeps nothing.
    class ResearchStore
      class Unavailable < StandardError; end

      URL_VARIABLE = "TRADING_LAB_DATABASE_URL"
      SCHEMA = "trading_lab"
      MIGRATIONS = File.expand_path("../../../db/migrate", __dir__)
      # Serializes migrations across processes starting together (pg_advisory_xact_lock).
      MIGRATION_LOCK = 4_207_193_001
      KINDS = %w[paper_replay copy_replay].freeze
      EXPERIMENT = /\A[a-z0-9][a-z0-9._-]{0,62}\z/
      MAX_PAGE = 100
      SUMMARY = "r.id, r.kind, e.name AS experiment, r.subject, r.options, r.input_digest, r.equity, r.net_pnl, " \
                "r.max_drawdown, r.created_at"

      def self.from_env(env = ENV)
        url = env[URL_VARIABLE].to_s
        url.empty? ? nil : new(url)
      end

      def self.digest(input)
        Digest::SHA256.hexdigest(JSON.generate(input))
      end

      def initialize(url)
        raise ArgumentError, "#{URL_VARIABLE} must be a postgres URL" unless url.to_s.match?(%r{\Apostgres(?:ql)?://})
        require "pg"
        @url = url.to_s
        @lock = Mutex.new
        @connection = nil
      end

      # Applies db/migrate/*.sql in name order, each in its own transaction. An applied file
      # is never run twice, and a file edited after it was applied stops the migration.
      def migrate!
        files = Dir[File.join(MIGRATIONS, "*.sql")].sort
        with do |db|
          db.exec("CREATE SCHEMA IF NOT EXISTS #{SCHEMA}")
          db.exec("CREATE TABLE IF NOT EXISTS #{SCHEMA}.schema_migrations (name text PRIMARY KEY, checksum text NOT NULL, " \
                  "applied_at timestamptz NOT NULL DEFAULT now())")
          files.map do |path|
            name = File.basename(path, ".sql")
            sql = File.read(path)
            checksum = Digest::SHA256.hexdigest(sql)
            db.transaction do
              db.exec_params("SELECT pg_advisory_xact_lock($1)", [MIGRATION_LOCK])
              applied = db.exec_params("SELECT checksum FROM #{SCHEMA}.schema_migrations WHERE name = $1", [name]).first
              if applied
                raise Unavailable, "migration #{name} changed after it was applied" unless applied["checksum"] == checksum
                next nil
              end
              db.exec(sql)
              db.exec_params("INSERT INTO #{SCHEMA}.schema_migrations (name, checksum) VALUES ($1, $2)", [name, checksum])
              name
            end
          end.compact
        end
      end

      # Stores one finished simulation and returns its id.
      def record_run(kind:, options:, input:, result:, portfolio:, subject: nil, experiment: nil)
        raise ArgumentError, "kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind)
        self.class.validate_experiment(experiment)
        with do |db|
          db.transaction do
            experiment_id = experiment && experiment_id(db, experiment)
            row = db.exec_params(
              "INSERT INTO #{SCHEMA}.simulation_runs (kind, experiment_id, subject, options, input_digest, equity, net_pnl, " \
              "max_drawdown, portfolio, result) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id",
              [kind, experiment_id, subject, JSON.generate(options), self.class.digest(input), result.fetch("equity"),
               result.fetch("net_pnl"), result["max_drawdown"], JSON.generate(portfolio), JSON.generate(result)]
            ).first
            Integer(row.fetch("id"), 10)
          end
        end
      end

      # Newest first, without the full result. `before` is the id to page back from.
      def runs(kind: nil, subject: nil, experiment: nil, limit: 20, before: nil)
        raise ArgumentError, "kind must be one of #{KINDS.join(', ')}" if kind && !KINDS.include?(kind)
        self.class.validate_experiment(experiment)
        raise ArgumentError, "limit must be between 1 and #{MAX_PAGE}" unless limit.is_a?(Integer) && (1..MAX_PAGE).cover?(limit)
        raise ArgumentError, "before must be a positive id" unless before.nil? || (before.is_a?(Integer) && before.positive?)
        with do |db|
          db.exec_params(
            "SELECT #{SUMMARY} FROM #{SCHEMA}.simulation_runs r LEFT JOIN #{SCHEMA}.experiments e ON e.id = r.experiment_id " \
            "WHERE ($1::text IS NULL OR r.kind = $1) AND ($2::text IS NULL OR r.subject = $2) " \
            "AND ($3::text IS NULL OR e.name = $3) AND ($4::bigint IS NULL OR r.id < $4) ORDER BY r.id DESC LIMIT $5",
            [kind, subject, experiment, before, limit]
          ).map { |row| summary(row) }
        end
      end

      def run(id)
        raise ArgumentError, "id must be a positive integer" unless id.is_a?(Integer) && id.positive?
        with do |db|
          row = db.exec_params(
            "SELECT #{SUMMARY}, r.portfolio, r.result FROM #{SCHEMA}.simulation_runs r " \
            "LEFT JOIN #{SCHEMA}.experiments e ON e.id = r.experiment_id WHERE r.id = $1", [id]
          ).first
          row && summary(row).merge("portfolio" => JSON.parse(row["portfolio"]), "result" => JSON.parse(row["result"]))
        end
      end

      def self.validate_experiment(name)
        raise ArgumentError, "experiment must match #{EXPERIMENT.source}" unless name.nil? || (name.is_a?(String) && EXPERIMENT.match?(name))
      end

      # Runs the block with the one shared connection. A dropped connection is replaced once;
      # every database failure surfaces as Unavailable so callers need not know the driver.
      def with
        @lock.synchronize do
          attempts = 0
          begin
            attempts += 1
            yield connection
          rescue PG::ConnectionBad, PG::UnableToSend
            @connection = nil
            retry if attempts < 2
            raise Unavailable, "research store is unreachable"
          rescue PG::Error => error
            raise Unavailable, "research store failed: #{error.class}"
          end
        end
      end

      private

      def connection
        return @connection if @connection && !@connection.finished?
        @connection = PG.connect(@url, connect_timeout: 5)
        @connection.exec("SET statement_timeout = '10s'; SET client_min_messages = warning")
        @connection
      end

      def experiment_id(db, name)
        db.exec_params("INSERT INTO #{SCHEMA}.experiments (name) VALUES ($1) ON CONFLICT (name) DO NOTHING", [name])
        Integer(db.exec_params("SELECT id FROM #{SCHEMA}.experiments WHERE name = $1", [name]).first.fetch("id"), 10)
      end

      # Decimals stay strings, as everywhere else at the service boundary.
      def summary(row)
        {
          "id" => Integer(row["id"], 10), "kind" => row["kind"], "experiment" => row["experiment"], "subject" => row["subject"],
          "options" => JSON.parse(row["options"]), "input_digest" => row["input_digest"], "equity" => row["equity"],
          "net_pnl" => row["net_pnl"], "max_drawdown" => row["max_drawdown"],
          "created_at" => Time.parse(row["created_at"]).utc.iso8601(6)
        }
      end
    end
  end
end
