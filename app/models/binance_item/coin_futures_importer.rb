# frozen_string_literal: true

# Fetches COIN-M Futures equity by settlement asset.
class BinanceItem::CoinFuturesImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    raw = provider.get_coin_futures_account
    assets = Array(raw["assets"]).filter_map { |asset| normalize(asset) }

    { assets: assets, raw: raw, source: "coin_futures" }
  rescue Provider::Binance::RateLimitError
    raise
  rescue => e
    Rails.logger.error "BinanceItem::CoinFuturesImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "coin_futures", error: e.message }
  end

  private

    def normalize(asset)
      wallet = asset["walletBalance"].to_d
      unrealized = asset["unrealizedProfit"].to_d
      total = asset["marginBalance"].presence&.to_d || wallet + unrealized
      return if total.zero?

      free = asset["availableBalance"].presence&.to_d || wallet
      {
        symbol: asset["asset"],
        free: free.to_s("F"),
        locked: (wallet - free).to_s("F"),
        total: total.to_s("F")
      }
    end
end
