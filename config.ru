# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true
require "bundler/setup"
require_relative "lib/zero_x_da/trading_lab/http_app"
# A configured store must be usable before traffic is served: migrations are idempotent and
# serialized by an advisory lock, and a database that cannot be reached stops the boot.
store = ZeroXDA::TradingLab::ResearchStore.from_env
store&.migrate!
run ZeroXDA::TradingLab::HTTPApp.new(store: store)
