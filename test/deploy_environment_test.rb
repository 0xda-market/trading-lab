# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "yaml"
require_relative "../lib/zero_x_da/trading_lab/http_app"

class DeployEnvironmentTest < Minitest::Test
  Lab = ZeroXDA::TradingLab
  BLUEPRINT = File.expand_path("../render.yaml", __dir__)

  def health(**options)
    app = Lab::HTTPApp.new(token: "test-secret", store: nil, **options)
    status, _headers, body = app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/health", "QUERY_STRING" => "",
                                      "rack.input" => StringIO.new(""))
    [status, body.join]
  end

  def test_known_targets_are_accepted
    assert_equal "development", Lab::DeployEnvironment.from_env("DEPLOY_ENV" => "development")
    assert_equal "production", Lab::DeployEnvironment.from_env("DEPLOY_ENV" => "production")
  end

  def test_an_absent_target_stays_unnamed
    assert_nil Lab::DeployEnvironment.from_env({})
    assert_nil Lab::DeployEnvironment.from_env("DEPLOY_ENV" => "")
  end

  def test_an_unknown_target_stops_the_boot
    ["test", "staging", "Development", " development", "production\n"].each do |name|
      error = assert_raises(ArgumentError, name.inspect) { Lab::DeployEnvironment.from_env("DEPLOY_ENV" => name) }
      assert_equal "DEPLOY_ENV must be development or production", error.message
      assert_raises(ArgumentError, name.inspect) { Lab::HTTPApp.new(token: "test-secret", store: nil, environment: name) }
    end
  end

  # Production infra starts the service without DEPLOY_ENV; its health document must not move.
  def test_health_is_unchanged_without_a_target
    assert_equal [200, '{"status":"ok"}'], health(environment: nil)
  end

  def test_health_names_the_declared_target
    assert_equal [200, '{"status":"ok","environment":"development"}'], health(environment: "development")
    assert_equal [200, '{"status":"ok","environment":"production"}'], health(environment: "production")
  end

  def test_the_service_reads_its_target_from_the_environment
    previous = ENV.fetch("DEPLOY_ENV", nil)
    ENV["DEPLOY_ENV"] = "development"
    assert_equal [200, '{"status":"ok","environment":"development"}'], health
    ENV["DEPLOY_ENV"] = "preview"
    assert_raises(ArgumentError) { health }
  ensure
    previous ? ENV["DEPLOY_ENV"] = previous : ENV.delete("DEPLOY_ENV")
  end

  def test_a_declared_target_does_not_open_the_api
    app = Lab::HTTPApp.new(token: "test-secret", store: nil, environment: "development")
    status, = app.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/paper/replays", "QUERY_STRING" => "",
                       "rack.input" => StringIO.new('{"events":[]}'))
    assert_equal 401, status
  end

  # The Render Blueprint is the development target for the TEST bot. These pin what keeps
  # it development-only: one hand-deployed service, no secret in Git and no database.
  def test_render_blueprint_is_a_manual_development_service
    blueprint = YAML.safe_load_file(BLUEPRINT)
    assert_equal %w[services], blueprint.keys
    assert_equal 1, blueprint.fetch("services").size
    service = blueprint.fetch("services").first
    assert_equal "0xda-market-test-trading-lab", service.fetch("name")
    assert_equal %w[web docker master /health off],
                 service.values_at("type", "runtime", "branch", "healthCheckPath", "autoDeployTrigger")
    variables = service.fetch("envVars").to_h { |variable| [variable.fetch("key"), variable.except("key")] }
    assert_equal %w[DEPLOY_ENV PORT TRADING_LAB_SERVICE_TOKEN], variables.keys
    assert_equal({ "value" => "development" }, variables.fetch("DEPLOY_ENV"))
    assert_equal "development", Lab::DeployEnvironment.validate(variables.dig("DEPLOY_ENV", "value"))
    assert_equal({ "value" => "10000" }, variables.fetch("PORT"))
    assert_equal({ "generateValue" => true }, variables.fetch("TRADING_LAB_SERVICE_TOKEN"))
  end
end
