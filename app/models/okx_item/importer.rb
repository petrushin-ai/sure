# frozen_string_literal: true

class OkxItem::Importer
  MIN_HOLDING_USD = BigDecimal("1")
  GRID_TYPES = %w[grid contract_grid].freeze

  class CoreAccountUnavailable < StandardError; end

  attr_reader :okx_item, :provider

  def initialize(okx_item, provider:)
    @okx_item = okx_item
    @provider = provider
  end

  def import
    core = trading_result
    raise CoreAccountUnavailable, core[:error] if core[:error].present?
    results = [ core ] + optional_results

    all_assets = results.flat_map { |result| tagged_assets(result) }
    all_assets += carried_over_assets(results)
    all_assets = consolidate_assets(all_assets)
    all_assets = apply_usd_cutoff(all_assets)

    if all_assets.empty? && okx_item.okx_accounts.find_by(account_type: "combined").nil?
      okx_item.upsert_okx_snapshot!(snapshot_payload(results))
      return { success: true, assets_imported: 0, total_usd: 0 }
    end

    total_usd = all_assets.sum { |asset| asset[:usd_value].to_d }.round(2)
    account = okx_item.okx_accounts.find_or_initialize_by(account_type: "combined")
    account.name = okx_item.name if account.new_record? || account.name.blank?
    account.assign_attributes(
      currency: "USD",
      current_balance: total_usd,
      institution_metadata: build_metadata(all_assets, results),
      raw_payload: raw_by_source(results).merge(
        "assets" => all_assets.map(&:stringify_keys),
        "source_status" => source_status(results),
        "dust_omitted" => @dust_omitted,
        "unpriced_assets" => @unpriced_assets,
        "minimum_holding_usd" => MIN_HOLDING_USD.to_s("F"),
        "fetched_at" => Time.current.iso8601
      ),
      raw_transactions_payload: history_payload
    )
    account.save!
    okx_item.upsert_okx_snapshot!(snapshot_payload(results))
    { success: true, assets_imported: all_assets.size, total_usd: total_usd }
  end

  private

    def trading_result
      source_result("trading", required: true) do
        raw = provider.get_account_balance
        details = Array(raw).flat_map { |row| Array(row["details"]) }
        assets = details.filter_map do |row|
          amount = row["eq"].presence || row["cashBal"]
          next if row["ccy"].blank? || amount.to_d.zero?
          asset(row["ccy"], amount, usd_value: row["eqUsd"], free: row["availEq"].presence || row["availBal"])
        end
        [ assets, raw ]
      end
    end

    def optional_results
      [
        source_result("funding") { raw = provider.get_funding_balances; [ rows_to_assets(raw, amount: "bal"), raw ] },
        source_result("non_tradable") { raw = provider.get_non_tradable_assets; [ rows_to_assets(raw, amount: "bal"), raw ] },
        source_result("simple_earn") { raw = provider.get_simple_earn_balances; [ rows_to_assets(raw, amount: "amt"), raw ] },
        source_result("onchain_earn") { raw = provider.get_onchain_earn_positions; [ nested_assets(raw, "investData"), raw ] },
        source_result("flexible_loans") { raw = provider.get_flexible_loans; [ loan_assets(raw), raw ] },
        source_result("dual_investment") { raw = provider.get_dual_investment_orders; [ dual_investment_assets(raw), raw ] },
        source_result("okusd") { raw = provider.get_okusd_balance; [ rows_to_assets(raw, amount: "amt"), raw ] },
        diagnostic_result("positions") { provider.get_positions },
        diagnostic_result("eth_staking_aggregate") { provider.get_eth_staking_balance },
        diagnostic_result("sol_staking_aggregate") { provider.get_sol_staking_balance },
        diagnostic_result("stable_rewards_aggregate") { provider.get_stable_rewards_balance },
        diagnostic_result("copy_trading") { provider.get_copy_positions },
        diagnostic_result("account_config") { provider.get_account_config },
        diagnostic_result("signal_bots") { provider.get_signal_bots },
        diagnostic_result("recurring_buys") { provider.get_recurring_buys },
        *GRID_TYPES.map { |type| diagnostic_result("bot_#{type}") { provider.get_grid_bots(type) } }
      ]
    end

    def source_result(source, required: false)
      assets, raw = yield
      { source: source, assets: assets, raw: raw, error: nil, required: required, diagnostic: false }
    rescue Provider::Okx::AuthenticationError, Provider::Okx::RateLimitError, Provider::Okx::TimestampError
      raise
    rescue StandardError => e
      { source: source, assets: [], raw: nil, error: e.message, required: required, diagnostic: false }
    end

    def diagnostic_result(source)
      raw = yield
      { source: source, assets: [], raw: raw, error: nil, required: false, diagnostic: true }
    rescue Provider::Okx::AuthenticationError, Provider::Okx::RateLimitError, Provider::Okx::TimestampError
      raise
    rescue StandardError => e
      { source: source, assets: [], raw: nil, error: e.message, required: false, diagnostic: true }
    end

    def rows_to_assets(rows, amount:)
      Array(rows).filter_map do |row|
        next if row["ccy"].blank? || row[amount].to_d.zero?
        asset(row["ccy"], row[amount], free: row["availBal"])
      end
    end

    def nested_assets(rows, field)
      Array(rows).flat_map { |row| Array(row[field]) }.filter_map do |position|
        next if position["ccy"].blank? || position["amt"].to_d.zero?
        asset(position["ccy"], position["amt"])
      end
    end

    def loan_assets(rows)
      Array(rows).flat_map do |row|
        collateral = Array(row["collateralData"]).filter_map do |position|
          asset(position["ccy"], position["amt"]) if position["ccy"].present? && !position["amt"].to_d.zero?
        end
        debt = Array(row["loanData"]).filter_map do |position|
          asset(position["ccy"], -position["amt"].to_d) if position["ccy"].present? && !position["amt"].to_d.zero?
        end
        collateral + debt
      end
    end

    def dual_investment_assets(rows)
      Array(rows).filter_map do |row|
        next if row["notionalCcy"].blank? || row["notionalSz"].to_d.zero?
        asset(row["notionalCcy"], row["notionalSz"])
      end
    end

    def asset(symbol, amount, usd_value: nil, free: nil)
      normalized = symbol.to_s.upcase
      {
        symbol: normalized, total: amount.to_d.to_s("F"),
        free: (free.presence || amount).to_d.to_s("F"), locked: "0",
        usd_value: usd_value.presence&.to_d&.to_s("F")
      }
    end

    def tagged_assets(result)
      result[:assets].map { |row| row.merge(source: result[:source], source_key: result[:source]) }
    end

    def carried_over_assets(results)
      failed_sources = results.reject { |r| r[:diagnostic] }.select { |r| r[:error].present? }.map { |r| r[:source] }
      return [] if failed_sources.empty?

      record_partial_failure(results.select { |r| failed_sources.include?(r[:source]) })
      previous = okx_item.okx_accounts.find_by(account_type: "combined")&.raw_payload&.dig("assets")
      Array(previous).map(&:deep_symbolize_keys).select { |row| failed_sources.include?(row[:source_key] || row[:source]) }
    end

    def consolidate_assets(assets)
      assets.group_by { |row| [ row[:symbol], row[:source] ] }.map do |(_symbol, _source), rows|
        first = rows.first
        direct_values = rows.filter_map { |row| row[:usd_value].presence&.to_d }
        first.merge(
          total: rows.sum { |row| row[:total].to_d }.to_s("F"),
          free: rows.sum { |row| row[:free].to_d }.to_s("F"),
          locked: rows.sum { |row| row[:locked].to_d }.to_s("F"),
          usd_value: direct_values.size == rows.size ? direct_values.sum.to_s("F") : nil
        )
      end
    end

    def record_partial_failure(failed)
      DebugLogEntry.capture(
        category: "provider_sync", level: "warn", message: "OKX import read only part of the account",
        source: self.class.name, provider_key: "okx", family: okx_item.family,
        metadata: { okx_item_id: okx_item.id, unavailable_sources: failed.map { |r| r[:source] }, errors: failed.to_h { |r| [ r[:source], r[:error] ] } }
      )
    end

    def apply_usd_cutoff(assets)
      @dust_omitted = []
      @unpriced_assets = []
      assets.filter_map do |row|
        direct_value = row[:usd_value].presence&.to_d
        price = if direct_value && !row[:total].to_d.zero?
          direct_value / row[:total].to_d
        else
          price_for(row[:symbol]) || previous_price_for(row)
        end

        if price.nil?
          @unpriced_assets << { "symbol" => row[:symbol], "source" => row[:source] }
          next row.merge(usd_price: nil, usd_value: nil, price_status: "unavailable")
        end

        value = row[:total].to_d * price
        if value.abs < MIN_HOLDING_USD
          @dust_omitted << { "symbol" => row[:symbol], "source" => row[:source], "usd_value" => value.to_s("F") }
          next
        end

        row.merge(usd_price: price.to_s("F"), usd_value: value.to_s("F"), price_status: "current")
      end
    end

    def price_for(symbol)
      return BigDecimal("1") if OkxAccount::STABLECOINS.include?(symbol)
      @price_cache ||= {}
      @price_cache[symbol] = provider.get_market_price(symbol).presence&.to_d unless @price_cache.key?(symbol)
      @price_cache[symbol]
    end

    def previous_price_for(row)
      previous_priced_assets[[ row[:symbol], row[:source] ]]&.dig("usd_price")&.to_d
    end

    def previous_priced_assets
      @previous_priced_assets ||= Array(okx_item.okx_accounts.find_by(account_type: "combined")&.raw_payload&.dig("assets"))
        .select { |row| row["usd_price"].present? }
        .index_by { |row| [ row["symbol"], row["source"] ] }
    end

    def history_payload
      payload = {
        "account_bills" => safe_history { provider.get_account_bills },
        "funding_bills" => safe_history { provider.get_funding_bills },
        "deposits" => safe_history { provider.get_deposit_history },
        "withdrawals" => safe_history { provider.get_withdrawal_history },
        "convert" => safe_history { provider.get_convert_history },
        "fills" => %w[SPOT MARGIN SWAP FUTURES OPTION].to_h { |type| [ type.downcase, safe_history { provider.get_fills_history(type) } ] },
        "fetched_at" => Time.current.iso8601
      }
      payload
    end

    def safe_history
      yield
    rescue Provider::Okx::AuthenticationError, Provider::Okx::RateLimitError, Provider::Okx::TimestampError
      raise
    rescue StandardError => e
      { "status" => "unavailable", "error" => e.message }
    end

    def raw_by_source(results)
      results.to_h { |result| [ result[:source], result[:raw] ] }
    end

    def source_status(results)
      results.to_h do |result|
        status = result[:error].present? ? { "status" => "unavailable", "error" => result[:error] } : { "status" => "ok", "asset_count" => result[:assets].size, "diagnostic_only" => result[:diagnostic] }
        [ result[:source], status ]
      end
    end

    def snapshot_payload(results)
      raw_by_source(results).merge(
        "source_status" => source_status(results), "dust_omitted" => @dust_omitted || [],
        "unpriced_assets" => @unpriced_assets || [], "minimum_holding_usd" => MIN_HOLDING_USD.to_s("F"),
        "imported_at" => Time.current.iso8601
      )
    end

    def build_metadata(assets, results)
      {
        "sources" => assets.group_by { |row| row[:source_key] }.transform_values { |rows| { "asset_count" => rows.size, "assets" => rows.map { |r| r[:symbol] }.uniq } },
        "diagnostics" => results.select { |r| r[:diagnostic] }.to_h { |r| [ r[:source], r[:error].present? ? "unavailable" : "ok" ] }
      }
    end
end
