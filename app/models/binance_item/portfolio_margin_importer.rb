# frozen_string_literal: true

# Portfolio Margin consolidates cross margin and derivatives. When available it
# replaces the overlapping standalone Margin/Futures/Options sources.
class BinanceItem::PortfolioMarginImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    errors = []

    begin
      raw = provider.get_portfolio_margin_pro_balance
      return result(raw, mode: "pro")
    rescue Provider::Binance::RateLimitError
      raise
    rescue => e
      errors << "pro: #{e.message}"
    end

    begin
      raw = provider.get_portfolio_margin_balance
      return result(raw, mode: "classic")
    rescue Provider::Binance::RateLimitError
      raise
    rescue => e
      errors << "classic: #{e.message}"
    end

    { assets: [], raw: nil, source: "portfolio_margin", error: errors.join("; ") }
  end

  private

    def result(raw, mode:)
      assets = Array(raw).filter_map { |asset| normalize(asset) }
      {
        assets: assets,
        raw: { "mode" => mode, "balances" => raw },
        source: "portfolio_margin",
        aggregate: true
      }
    end

    def normalize(asset)
      wallet = asset["totalWalletBalance"].to_d
      derivatives_pnl = asset["umUnrealizedPNL"].to_d + asset["cmUnrealizedPNL"].to_d
      options_pnl = asset["optionEquity"].to_d - asset["optionWalletBalance"].to_d
      total = wallet + derivatives_pnl + options_pnl
      return if total.zero?

      free = asset["crossMarginFree"].to_d + asset["umWalletBalance"].to_d +
        asset["cmWalletBalance"].to_d + asset["optionWalletBalance"].to_d

      {
        symbol: asset["asset"],
        free: free.to_s("F"),
        locked: (total - free).to_s("F"),
        total: total.to_s("F")
      }
    end
end
