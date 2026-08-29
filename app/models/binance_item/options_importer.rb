# frozen_string_literal: true

# Fetches standalone Binance Options account equity.
class BinanceItem::OptionsImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    raw = provider.get_options_account
    assets = Array(raw["asset"]).filter_map do |asset|
      total = asset["equity"].presence&.to_d || asset["marginBalance"].to_d
      next if total.zero?

      free = asset["available"].to_d
      {
        symbol: asset["asset"],
        free: free.to_s("F"),
        locked: (total - free).to_s("F"),
        total: total.to_s("F")
      }
    end

    { assets: assets, raw: raw, source: "options" }
  rescue Provider::Binance::AuthenticationError, Provider::Binance::RateLimitError
    raise
  rescue => e
    Rails.logger.error "BinanceItem::OptionsImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "options", error: e.message }
  end
end
