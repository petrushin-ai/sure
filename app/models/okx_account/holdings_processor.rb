class OkxAccount::HoldingsProcessor
  include OkxAccount::UsdConverter

  def initialize(okx_account)
    @okx_account = okx_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    assets = okx_account.raw_payload&.dig("assets")
    return if assets.nil?

    assets = aggregate_by_symbol(assets)
    assets.each { |row| process_asset(row) }
    cleanup_stale_holdings!(assets)
  end

  private

    attr_reader :okx_account
    def account
      okx_account.current_account
    end

    def target_currency
      okx_account.okx_item.family.currency
    end

    def process_asset(row)
      symbol = row["symbol"].presence || row[:symbol]
      total = (row["total"] || row[:total]).to_d
      source = row["source"] || row[:source]
      return if symbol.blank? || !total.positive?

      price_usd = (row["usd_price"] || row[:usd_price]).presence&.to_d
      price_usd ||= OkxAccount::STABLECOINS.include?(symbol) ? BigDecimal("1") : okx_account.okx_item.okx_provider&.get_market_price(symbol)&.to_d
      return unless price_usd
      return if total * price_usd < OkxItem::Importer::MIN_HOLDING_USD

      security = OkxAccount::SecurityResolver.resolve(symbol)
      return unless security

      amount, = convert_from_usd(total * price_usd)
      price, = convert_from_usd(price_usd)
      Account::ProviderImportAdapter.new(account).import_holding(
        security: security, quantity: total, amount: amount, currency: target_currency,
        date: Date.current, price: price, cost_basis: nil,
        external_id: external_id(symbol, source), account_provider_id: okx_account.account_provider&.id,
        source: "okx", delete_future_holdings: false
      )
    rescue StandardError => e
      Rails.logger.error("OkxAccount::HoldingsProcessor - failed #{symbol}: #{e.message}")
    end

    def cleanup_stale_holdings!(assets)
      provider_id = okx_account.account_provider&.id
      return unless provider_id

      keep = assets.filter_map do |row|
        total = (row["total"] || row[:total]).to_d
        external_id(row["symbol"] || row[:symbol], row["source"] || row[:source]) if total.positive?
      end
      scope = account.holdings.where(account_provider_id: provider_id, date: Date.current)
      scope = scope.where.not(external_id: keep) if keep.any?
      scope.delete_all
    end

    def external_id(symbol, _source = nil)
      "okx_#{symbol}_combined_#{Date.current}"
    end

    # Keep one materialized position per asset in the combined account. OKX
    # source rows remain available in raw_payload for diagnostics, while this
    # sum prevents Trading/Funding/Earn rows for one asset from overwriting one
    # another at Holding's composite unique key.
    def aggregate_by_symbol(assets)
      assets
        .select { |row| (row["total"] || row[:total]).to_d.positive? }
        .group_by { |row| (row["symbol"] || row[:symbol]).to_s.upcase }
        .filter_map do |symbol, rows|
          next if symbol.blank?

          prices = rows.filter_map { |row| (row["usd_price"] || row[:usd_price]).presence&.to_d }
          {
            "symbol" => symbol,
            "total" => rows.sum { |row| (row["total"] || row[:total]).to_d }.to_s("F"),
            "source" => "combined",
            "usd_price" => prices.first&.to_s("F")
          }
        end
    end
end
