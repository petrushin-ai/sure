# frozen_string_literal: true

# Resolves or creates the canonical local Security for a Binance asset.
#
# Generic provider search is intentionally not used here. A bare crypto symbol
# such as CRYPTO:BTC can otherwise fuzzy-match an arbitrary market pair (for
# example BTCBRL). That changes the holding's identity and currency, and makes
# Sure request a foreign-exchange rate for every historical holding date.
class BinanceAccount::SecurityResolver
  EXCHANGE_MIC = "XBNC"

  def self.resolve(ticker, symbol)
    normalized_ticker = ticker.to_s.strip.upcase

    Security.find_by(ticker: normalized_ticker) ||
      Security.create!(
        ticker: normalized_ticker,
        name: symbol,
        exchange_operating_mic: EXCHANGE_MIC,
        offline: true
      )
  rescue ActiveRecord::RecordNotUnique
    Security.find_by!(ticker: normalized_ticker)
  rescue StandardError => e
    Rails.logger.warn "BinanceAccount::SecurityResolver - canonical resolution failed for #{ticker}: #{e.message}"
    nil
  end
end
