require "json"

require_relative "agentd/version"
require_relative "agentd/error"
require_relative "agentd/config"
require_relative "agentd/client"
require_relative "agentd/agent"
require_relative "agentd/runner"

module Agentd
  class << self
    attr_writer :endpoint, :api_key

    def configure
      yield self
    end

    def endpoint
      @endpoint || config.endpoint || "https://agentd.link"
    end

    def api_key
      @api_key || config.api_key || ENV["AGENTD_API_KEY"]
    end

    def config
      @config ||= Config.load
    end

    # Convenience: Agentd.agent acts as the default agent client
    def agent
      @agent ||= Agent.new(api_key:, endpoint:)
    end
  end
end
