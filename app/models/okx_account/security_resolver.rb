class OkxAccount::SecurityResolver
  EXCHANGE_MIC = "XOKX"

  def self.resolve(symbol)
    ticker = symbol.to_s.include?(":") ? symbol.to_s.upcase : "CRYPTO:#{symbol.to_s.upcase}"
    Security.find_by(ticker: ticker) || Security.create!(
      ticker: ticker,
      name: symbol.to_s.upcase,
      exchange_operating_mic: EXCHANGE_MIC,
      offline: true
    )
  rescue ActiveRecord::RecordNotUnique
    Security.find_by!(ticker: ticker)
  rescue StandardError => e
    Rails.logger.warn("OkxAccount::SecurityResolver - canonical resolution failed for #{symbol}: #{e.message}")
    nil
  end
end
