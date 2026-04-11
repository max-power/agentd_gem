module Agentd
  # High-level agent interface. Wraps the MCP tools in plain Ruby methods.
  #
  # Usage (existing agent):
  #   agent = Agentd::Agent.new(api_key: "...", endpoint: "http://localhost:3000")
  #   agent.publish(:note, body: "Hello world")
  #   agent.send_message(:email, to: "someone@example.com", body: "Hi")
  #   task = agent.delegate_task(to: "researcher-001", title: "...", instructions: "...")
  #
  # Usage (provisioning a new agent):
  #   attrs = Agentd::Agent.provision(handle: "my-agent", capabilities: ["research"])
  #   agent = Agentd::Agent.new(api_key: attrs[:api_key])
  #
  class Agent
    attr_reader :client, :identity

    def initialize(api_key:, endpoint: Agentd.endpoint)
      @client = Client.new(api_key:, endpoint:)
    end

    # --- Provisioning ---

    def self.provision(handle:, endpoint: Agentd.endpoint, **opts)
      admin_client = Client.new(api_key: nil, endpoint:)
      admin_client.provision(handle:, **opts)
    end

    # --- Identity ---

    def identity
      @identity ||= client.tool("get_identity")
    end

    def handle       = identity["handle"]
    def did          = identity["did"]
    def email        = identity["email"]
    def nostr_npub   = identity["nostr_npub"]

    # --- Publishing ---

    def publish(type, **content)
      client.tool("publish", type: type.to_s, content: content.transform_keys(&:to_s))
    end

    def publications(type: nil, page: 1, per: 20)
      client.tool("list_publications", **{ type:, page:, per: }.compact)
    end

    # --- Context store ---

    def context_get(key)          = client.tool("context_get",    key:)["value"]
    def context_set(key, value)   = client.tool("context_set",    key:, value:)
    def context_delete(key)       = client.tool("context_delete", key:)
    def context_list              = client.tool("context_list")
    def context_all
      context_list.each_with_object({}) { |key, h| h[key] = context_get(key) }
    end

    # --- Signing & verification ---

    def sign(payload)
      client.tool("sign", payload: payload)
    end

    def verify(payload:, signature:, wallet_address:)
      client.tool("verify", payload:, signature:, wallet_address:)["valid"]
    end

    # --- Tasks ---

    def inbox(limit: 10)
      client.tool("inbox_peek", limit:)
    end

    def claim_task(task_id)
      client.tool("task_claim", task_id:)
    end

    def complete_task(task_id, result:)
      client.tool("task_complete", task_id:, result:)
    end

    def fail_task(task_id, reason:)
      client.tool("task_fail", task_id:, reason:)
    end

    def delegate_task(to:, title:, instructions:, payload: {})
      client.tool("task_delegate", handle: to, title:, instructions:, payload:)
    end

    def task_result(task_id)
      client.tool("task_result", task_id:)
    end

    def lookup_agent(handle)
      client.tool("agent_lookup", handle:)
    end

    # --- Messaging ---

    def send_message(channel, to:, body:, subject: nil, **metadata)
      client.tool("send_message",
        channel:,
        recipient: to,
        body:,
        subject:,
        metadata: metadata.empty? ? nil : metadata
      )
    end

    def messages(channel: nil, direction: nil, page: 1, per: 20)
      client.tool("list_messages", **{ channel:, direction:, page:, per: }.compact)
    end

    # --- Memory ---

    def memory_store(key, content, namespace: nil)
      client.tool("memory_store", **{ key:, content:, namespace: }.compact)
    end

    def memory_search(query, limit: 10, namespace: nil)
      client.tool("memory_search", **{ query:, limit:, namespace: }.compact)
    end

    def memory_list(namespace: nil, page: 1, per: 50)
      client.tool("memory_list", **{ namespace:, page:, per: }.compact)
    end

    def memory_delete(key, namespace: nil)
      client.tool("memory_delete", **{ key:, namespace: }.compact)
    end

    def dream
      client.tool("dream")
    end

    # --- Payments ---

    def fetch(url, method: "GET", max_amount_usdc: nil, **opts)
      client.tool("fetch_with_payment",
        url:,
        method:,
        max_amount_usdc:,
        **opts
      )
    end

    def payments(status: nil, page: 1, per: 20)
      client.tool("list_payments", **{ status:, page:, per: }.compact)
    end
  end
end
