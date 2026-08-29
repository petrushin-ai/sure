# frozen_string_literal: true

class Provider::Okx
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class TimestampError < Error; end
  class CapabilityError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://www.okx.com".freeze
  AUTH_CODES = %w[50101 50103 50104 50105 50106 50107 50111 50113 50114 50115 50116 50119 50120].freeze
  RATE_LIMIT_CODES = %w[50011 50040].freeze
  TIMESTAMP_CODES = %w[50102].freeze
  OPTIONAL_MESSAGES = /not (?:available|supported|enabled)|does not exist|no permission|account mode|not activated|not open/i
  PAGE_LIMIT = 100
  MAX_PAGES = 50

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret, :passphrase

  def initialize(api_key:, api_secret:, passphrase:)
    @api_key = api_key
    @api_secret = api_secret
    @passphrase = passphrase
    @clock_offset = 0
  end

  def get_account_balance
    signed_get("/api/v5/account/balance")
  end

  def get_positions
    paginate("/api/v5/account/positions", cursor: "after")
  end

  def get_funding_balances
    signed_get("/api/v5/asset/balances")
  end

  def get_non_tradable_assets
    signed_get("/api/v5/asset/non-tradable-assets")
  end

  def get_simple_earn_balances
    signed_get("/api/v5/finance/savings/balance")
  end

  def get_onchain_earn_positions
    paginate("/api/v5/finance/staking-defi/orders-active", cursor: "after")
  end

  def get_eth_staking_balance
    signed_get("/api/v5/finance/staking-defi/eth/balance")
  end

  def get_sol_staking_balance
    signed_get("/api/v5/finance/staking-defi/sol/balance")
  end

  def get_okusd_balance
    signed_get("/api/v5/finance/okusd/account")
  end

  def get_stable_rewards_balance
    signed_get("/api/v5/finance/stable-rewards/balance")
  end

  def get_flexible_loans
    signed_get("/api/v5/finance/flexible-loan/loan-info")
  end

  def get_dual_investment_orders
    active_states = %w[initial live pending_settle pending_redeem]
    paginate("/api/v5/finance/sfp/dcd/order-history", cursor: "endId")
      .select { |row| active_states.include?(row["state"]) }
  end

  # Account and Funding bills are global ledgers. They cover spot, margin,
  # derivatives, Earn/Staking, structured products, loans, bots/copy trading,
  # deposits, withdrawals, P2P and internal transfers without guessing symbols
  # from today's holdings.
  def get_account_bills
    recent = paginate("/api/v5/account/bills", cursor: "after")
    archive = begin
      paginate("/api/v5/account/bills-archive", cursor: "after")
    rescue CapabilityError, ApiError
      []
    end
    deduplicate(recent + archive, "billId")
  end

  def get_funding_bills
    paginate("/api/v5/asset/bills", cursor: "after")
  end

  def get_deposit_history
    paginate("/api/v5/asset/deposit-history", cursor: "after")
  end

  def get_withdrawal_history
    paginate("/api/v5/asset/withdrawal-history", cursor: "after")
  end

  def get_convert_history
    paginate("/api/v5/asset/convert/history", cursor: "after")
  end

  def get_fills_history(inst_type)
    paginate("/api/v5/trade/fills-history", params: { "instType" => inst_type }, cursor: "after")
  end

  # Diagnostic-only product inventories. Their value is already included in
  # unified trading equity, so callers must never add these rows to holdings.
  def get_grid_bots(algo_ord_type)
    paginate("/api/v5/tradingBot/grid/orders-algo-pending", params: { "algoOrdType" => algo_ord_type }, cursor: "after")
  end

  def get_signal_bots
    paginate("/api/v5/tradingBot/signal/orders-algo-pending", params: { "algoOrdType" => "contract" }, cursor: "after")
  end

  def get_recurring_buys
    paginate("/api/v5/tradingBot/recurring/orders-algo-pending", cursor: "after")
  end

  def get_account_config
    signed_get("/api/v5/account/config")
  end

  def get_copy_positions
    paginate("/api/v5/copytrading/current-subpositions", cursor: "after")
  end

  def get_market_price(symbol)
    %w[USDT USDC USD].each do |quote|
      response = public_get("/api/v5/market/ticker", { "instId" => "#{symbol}-#{quote}" })
      last = Array(response).first&.dig("last")
      return last if last.present?
    rescue ApiError, CapabilityError
      next
    end
    nil
  end

  private

    def signed_get(path, params = {}, retried_timestamp: false)
      request_path = build_request_path(path, params)
      timestamp = (Time.current + @clock_offset).utc.iso8601(3)
      response = self.class.get(
        request_path,
        base_uri: BASE_URL,
        headers: auth_headers(timestamp, request_path)
      )
      handle_response(response)
    rescue TimestampError
      raise if retried_timestamp

      refresh_clock_offset!
      signed_get(path, params, retried_timestamp: true)
    end

    def public_get(path, params = {})
      response = self.class.get(path, base_uri: BASE_URL, query: params)
      handle_response(response)
    end

    def paginate(path, params: {}, cursor:)
      rows = []
      next_cursor = nil
      pages = 0

      loop do
        query = params.merge("limit" => PAGE_LIMIT.to_s)
        query[cursor] = next_cursor if next_cursor.present?
        page = signed_get(path, query)
        batch = Array(page)
        rows.concat(batch)
        pages += 1
        break if batch.size < PAGE_LIMIT
        break if pages >= MAX_PAGES

        next_cursor = batch.last["billId"] || batch.last["tradeId"] || batch.last["algoId"] || batch.last["ordId"] || batch.last["posId"] || batch.last["uTime"] || batch.last["ts"]
        break if next_cursor.blank?
      end

      rows
    end

    def refresh_clock_offset!
      response = public_get("/api/v5/public/time")
      server_ms = Array(response).first&.dig("ts").to_i
      raise TimestampError, "OKX server time unavailable" if server_ms.zero?

      @clock_offset = Time.at(server_ms / 1000.0) - Time.current
    end

    def build_request_path(path, params)
      return path if params.blank?

      "#{path}?#{URI.encode_www_form(params.sort)}"
    end

    def auth_headers(timestamp, request_path)
      payload = "#{timestamp}GET#{request_path}"
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", api_secret, payload))
      {
        "OK-ACCESS-KEY" => api_key,
        "OK-ACCESS-SIGN" => signature,
        "OK-ACCESS-TIMESTAMP" => timestamp,
        "OK-ACCESS-PASSPHRASE" => passphrase,
        "Content-Type" => "application/json"
      }
    end

    def handle_response(response)
      body = response.parsed_response
      if body.is_a?(String) && body.match?(/<!doctype|<html/i)
        raise ApiError, "Unexpected HTML response from OKX"
      end

      code = body.is_a?(Hash) ? body["code"].to_s : ""
      message = sanitized_message(body)

      raise RateLimitError, message if response.code == 429 || RATE_LIMIT_CODES.include?(code)
      raise AuthenticationError, message if response.code == 401 || AUTH_CODES.include?(code)
      raise TimestampError, message if TIMESTAMP_CODES.include?(code)
      raise CapabilityError, message if response.code == 403 || (code.present? && code != "0" && message.match?(OPTIONAL_MESSAGES))
      raise ApiError, message unless response.code.between?(200, 299) && (code.blank? || code == "0")

      body.is_a?(Hash) && body.key?("data") ? body["data"] : body
    end

    def sanitized_message(body)
      message = body.is_a?(Hash) ? body["msg"].to_s : ""
      message = "OKX API request failed" if message.blank?
      message.gsub(/<[^>]+>/, "").slice(0, 240)
    end

    def deduplicate(rows, key)
      rows.index_by { |row| row[key].presence || row.to_json }.values
    end
end
