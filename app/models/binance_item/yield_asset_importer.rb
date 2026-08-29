# frozen_string_literal: true

# Fetches Binance's dedicated BFUSD and RWUSD yield accounts. These products
# sit outside the ordinary Simple Earn position endpoints.
class BinanceItem::YieldAssetImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    @errors = {}
    bfusd = fetch(:bfusd) { provider.get_bfusd_account }
    rwusd = fetch(:rwusd) { provider.get_rwusd_account }
    assets = [
      normalized_asset("BFUSD", bfusd&.dig("bfusdAmount")),
      normalized_asset("RWUSD", rwusd&.dig("rwusdAmount"))
    ].compact

    result = {
      assets: assets,
      raw: { "bfusd" => bfusd, "rwusd" => rwusd },
      source: "yield_assets"
    }
    result[:error] = errors.values.join("; ") if bfusd.nil? && rwusd.nil?
    result
  rescue Provider::Binance::AuthenticationError, Provider::Binance::RateLimitError
    raise
  rescue => e
    Rails.logger.error "BinanceItem::YieldAssetImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "yield_assets", error: e.message }
  end

  private

    def fetch(name)
      yield
    rescue Provider::Binance::AuthenticationError, Provider::Binance::RateLimitError
      raise
    rescue => e
      errors[name] = e.message
      nil
    end

    def errors
      @errors ||= {}
    end

    def normalized_asset(symbol, amount)
      total = amount.to_d
      return if total.zero?

      { symbol: symbol, free: total.to_s("F"), locked: "0.0", total: total.to_s("F") }
    end
end
