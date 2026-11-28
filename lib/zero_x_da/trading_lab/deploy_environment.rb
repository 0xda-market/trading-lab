# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

module ZeroXDA
  module TradingLab
    # The deployment target a service process was started for, named by DEPLOY_ENV like the
    # rest of 0xda-market. It is not RACK_ENV, which only puts Rack and Puma in production mode.
    #
    # The variable is optional: a process started without it behaves exactly as before and
    # reports no target. A value that is not a known target stops the boot, so a typo cannot
    # run as an unnamed environment.
    module DeployEnvironment
      VARIABLE = "DEPLOY_ENV"
      NAMES = %w[development production].freeze

      def self.from_env(env = ENV)
        validate(env[VARIABLE])
      end

      def self.validate(name)
        name = name.to_s
        return nil if name.empty?
        raise ArgumentError, "#{VARIABLE} must be development or production" unless NAMES.include?(name)

        name
      end
    end
  end
end
