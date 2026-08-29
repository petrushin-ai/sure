# frozen_string_literal: true

# Read-only TON Center API v3 client.
#
# It deliberately exposes only indexed reads used by the on-chain adapter. No
# method sends a BOC, invokes a contract, requests a signature or otherwise
# mutates TON. A per-family API key is optional; without one TON Center permits
# one request per second, so the client throttles accordingly.
class Provider::Toncenter
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://toncenter.com/api/v3"
  UNAUTHENTICATED_REQUEST_INTERVAL = 1.05
  AUTHENTICATED_REQUEST_INTERVAL = 0.11
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5
  API_PAGE_SIZE = 1_000

  Page = Data.define(:rows, :metadata, :truncated)

  class << self
    def throttle(key, interval)
      return if interval <= 0

      throttle_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        remaining = interval - (now - throttle_times.fetch(key, 0))
        sleep(remaining) if remaining.positive?
        throttle_times[key] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    private
      def throttle_mutex
        @throttle_mutex ||= Mutex.new
      end

      def throttle_times
        @throttle_times ||= {}
      end
  end

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["TONCENTER_URL"].presence || DEFAULT_BASE_URL
  end

  def initialize(api_key: nil, min_request_interval: nil, max_retries: MAX_RETRIES)
    @api_key = api_key.to_s.strip.presence
    @min_request_interval = min_request_interval || default_request_interval
    @max_retries = max_retries
  end

  def account_state(address)
    payload = get_json("/accountStates", address: address, include_boc: false)
    Array(payload["accounts"]).first
  end

  def jetton_wallets(owner_address, max_rows:)
    paginate(
      "/jetton/wallets",
      collection: "jetton_wallets",
      max_rows: max_rows,
      query: { owner_address: owner_address, exclude_zero_balance: true, sort: "desc" }
    )
  end

  def ton_transfers(account, start_utime:, max_rows:)
    paginate(
      "/actions",
      collection: "actions",
      max_rows: max_rows,
      query: {
        account: account,
        action_type: "ton_transfer",
        start_utime: start_utime,
        sort: "desc"
      }
    )
  end

  def jetton_transfers(owner_address, start_utime:, max_rows:)
    paginate(
      "/jetton/transfers",
      collection: "jetton_transfers",
      max_rows: max_rows,
      query: { owner_address: owner_address, start_utime: start_utime, sort: "desc" }
    )
  end

  private
    attr_reader :api_key, :min_request_interval, :max_retries

    def default_request_interval
      api_key.present? ? AUTHENTICATED_REQUEST_INTERVAL : UNAUTHENTICATED_REQUEST_INTERVAL
    end

    # Fetches one row beyond the caller's budget when possible. That extra row
    # is not returned; it only distinguishes an exact final page from a history
    # that continues beyond the configured limit.
    def paginate(path, collection:, max_rows:, query:)
      budget = [ max_rows.to_i, 1 ].max
      wanted = budget + 1
      rows = []
      metadata = {}
      offset = 0

      while rows.length < wanted
        limit = [ wanted - rows.length, API_PAGE_SIZE ].min
        payload = get_json(path, **query, limit: limit, offset: offset)
        page = Array(payload[collection])

        rows.concat(page)
        metadata.merge!(payload["metadata"].to_h)
        break if page.length < limit

        offset += page.length
      end

      Page.new(rows: rows.first(budget), metadata: metadata, truncated: rows.length > budget)
    end

    def get_json(path, **query)
      attempts = 0

      begin
        attempts += 1
        throttle_request
        response = translate_transport_errors do
          self.class.get(
            "#{self.class.base_url}#{path}",
            query: query.compact,
            headers: api_key.present? ? { "X-API-Key" => api_key } : {}
          )
        end
        handle_response(response)
      rescue RateLimitError => e
        raise if attempts > max_retries

        delay = RETRY_BASE_DELAY * (2**(attempts - 1))
        Rails.logger.warn("Provider::Toncenter - rate limited (attempt #{attempts}/#{max_retries}): #{e.message}")
        sleep(delay)
        retry
      end
    end

    def throttle_request
      # Adapters are short lived and one family may own several TON addresses.
      # A process-wide gate keeps those instances inside the provider's shared
      # per-key quota instead of letting every new object start at request zero.
      key = api_key.present? ? Digest::SHA256.hexdigest(api_key) : "anonymous"
      self.class.throttle(key, min_request_interval)
    end

    def handle_response(response)
      case response.code
      when 200..299
        payload = response.parsed_response
        raise ApiError, "Unexpected TON Center response" unless payload.is_a?(Hash)

        payload
      when 400, 404
        raise InvalidAddressError, "TON Center rejected the address"
      when 429
        raise RateLimitError, "TON Center rate limit exceeded"
      else
        raise ApiError, "TON Center API error: #{response.code}"
      end
    end
end
