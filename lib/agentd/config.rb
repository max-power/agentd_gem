require "json"

module Agentd
  # Loads config from ~/.agentd/config.json
  # Expected format: { "api_key": "...", "endpoint": "..." }
  class Config
    CONFIG_PATH = File.expand_path("~/.agentd/config.json")

    attr_reader :api_key, :endpoint

    def initialize(data = {})
      @api_key  = data["api_key"]
      @endpoint = data["endpoint"]
    end

    def self.load
      return new unless File.exist?(CONFIG_PATH)
      new(JSON.parse(File.read(CONFIG_PATH)))
    rescue JSON::ParserError
      new
    end

    def self.save(api_key:, endpoint: nil)
      dir = File.dirname(CONFIG_PATH)
      FileUtils.mkdir_p(dir)
      existing = load
      data = {
        "api_key"  => api_key || existing.api_key,
        "endpoint" => endpoint || existing.endpoint
      }.compact
      File.write(CONFIG_PATH, JSON.pretty_generate(data))
    end
  end
end
