# frozen_string_literal: true

# Orchestrates all Binance sub-importers and upserts a single combined BinanceAccount.
class BinanceItem::Importer
  MIN_HOLDING_USD = BigDecimal("1")

  # Every sub-importer swallows its own error and answers with an empty asset
  # list, so "the wallet is empty" and "nothing could be fetched" arrive here
  # looking identical. Raising on the second keeps the sync honest instead of
  # reporting a successful import of nothing.
  class AllRequestsFailed < StandardError; end

  attr_reader :binance_item, :binance_provider

  def initialize(binance_item, binance_provider:)
    @binance_item = binance_item
    @binance_provider = binance_provider
  end

  def import
    Rails.logger.info "BinanceItem::Importer #{binance_item.id} - starting import"

    results = base_results + margin_and_derivatives_results
    all_assets = results.flat_map { |result| tagged_assets(result) }

    if results.all? { |result| result[:error].present? }
      raise AllRequestsFailed, results.filter_map { |result| result[:error] }.uniq.join("; ")
    end

    # A source that failed tells us nothing about what it holds, and the
    # holdings processor removes anything missing from this list. Writing only
    # the sources that answered would therefore delete live positions on a
    # transient error or a permission-scoped key. Their last known assets are
    # carried instead: stale until the source answers again, which beats gone.
    all_assets += carried_over_assets(results)
    all_assets = apply_usd_cutoff(all_assets)

    # An emptied wallet still has to be written down. Returning here left the
    # previous payload in place, and the holdings processor reads that payload —
    # so assets already sold were re-imported as today's holdings on every sync
    # and never went away. Only skipped when there is nothing to correct yet.
    if all_assets.empty? && binance_item.binance_accounts.find_by(account_type: "combined").nil?
      return { success: true, assets_imported: 0, total_usd: 0 }
    end

    total_usd = all_assets.sum { |asset| asset[:usd_value].to_d }.round(2)

    upsert_binance_account(
      all_assets: all_assets,
      total_usd: total_usd,
      results: results
    )

    binance_item.upsert_binance_snapshot!(snapshot_payload(results))

    Rails.logger.info "BinanceItem::Importer #{binance_item.id} - imported #{all_assets.size} assets, total_usd=#{total_usd}"

    { success: true, assets_imported: all_assets.size, total_usd: total_usd }
  end

  private

    def base_results
      [
        BinanceItem::SpotImporter.new(binance_item, provider: binance_provider).import,
        BinanceItem::FundingImporter.new(binance_item, provider: binance_provider).import,
        BinanceItem::IsolatedMarginImporter.new(binance_item, provider: binance_provider).import,
        BinanceItem::EarnImporter.new(binance_item, provider: binance_provider).import,
        BinanceItem::YieldAssetImporter.new(binance_item, provider: binance_provider).import
      ]
    end

    def margin_and_derivatives_results
      portfolio = BinanceItem::PortfolioMarginImporter.new(binance_item, provider: binance_provider).import
      return [ portfolio ] if portfolio[:error].blank? && portfolio[:assets].any?

      [
        BinanceItem::MarginImporter.new(binance_item, provider: binance_provider).import,
        BinanceItem::FuturesImporter.new(binance_item, provider: binance_provider).import,
        BinanceItem::CoinFuturesImporter.new(binance_item, provider: binance_provider).import,
        BinanceItem::OptionsImporter.new(binance_item, provider: binance_provider).import
      ]
    end

    def tagged_assets(result)
      result[:assets].map do |asset|
        asset.merge(
          source: asset[:source].presence || result[:source],
          source_key: result[:source]
        )
      end
    end

    def carried_over_assets(results)
      failed = results.select { |result| result[:error].present? }
      return [] if failed.empty?

      # A partial failure returns normally, so it never reaches the rescue in
      # BinanceItem#import_latest_binance_data. Without this the only trace is
      # an application log line, and support has nothing against the connection
      # saying part of the wallet went unread.
      record_partial_failure(failed)

      sources = failed.map { |result| result[:source] }
      previous = binance_item.binance_accounts.find_by(account_type: "combined")&.raw_payload&.dig("assets")
      return [] if previous.blank?

      carried = previous
        .map(&:deep_symbolize_keys)
        .select { |asset| sources.include?(asset[:source_key].presence || asset[:source].to_s.split(":").first) }

      if carried.any?
        Rails.logger.warn(
          "BinanceItem::Importer #{binance_item.id} - carrying #{carried.size} asset(s) " \
          "from unavailable source(s): #{sources.join(', ')}"
        )
      end

      carried
    end

    def record_partial_failure(failed)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Binance import read only part of the wallet",
        source: self.class.name,
        provider_key: "binance",
        family: binance_item.family,
        metadata: {
          binance_item_id: binance_item.id,
          unavailable_sources: failed.map { |result| result[:source] },
          errors: failed.to_h { |result| [ result[:source], result[:error] ] }
        }
      )
    end

    def apply_usd_cutoff(assets)
      @dust_omitted = []
      @unpriced_assets = []

      assets.filter_map do |asset|
        current_price = price_for(asset[:symbol])
        stored_price = asset[:usd_price].presence&.to_d || previous_price_for(asset)
        price = current_price || stored_price

        # An unavailable quote is not evidence that a live position is dust.
        # Preserve it for the holdings processor and try again next sync.
        if price.nil?
          @unpriced_assets << { "symbol" => asset[:symbol], "source" => asset[:source] }
          next asset.merge(usd_price: nil, usd_value: nil, price_status: "unavailable")
        end

        value = asset[:total].to_d * price
        if value.abs < MIN_HOLDING_USD
          @dust_omitted << {
            "symbol" => asset[:symbol],
            "source" => asset[:source],
            "usd_value" => value.to_s("F")
          }
          next
        end

        asset.merge(
          usd_price: price.to_s("F"),
          usd_value: value.to_s("F"),
          price_status: current_price ? "current" : "stale"
        )
      end
    end

    def price_for(symbol)
      return BigDecimal("1") if BinanceAccount::STABLECOINS.include?(symbol)

      @price_cache ||= {}
      return @price_cache[symbol] if @price_cache.key?(symbol)

      @price_cache[symbol] = %w[USDT BUSD FDUSD].filter_map do |quote|
        binance_provider.get_spot_price("#{symbol}#{quote}").presence&.to_d
      end.first
    rescue Provider::Binance::RateLimitError
      raise
    rescue => e
      Rails.logger.warn "BinanceItem::Importer - could not get price for #{symbol}: #{e.message}"
      nil
    end

    def previous_price_for(asset)
      previous = previous_priced_assets[[ asset[:symbol], asset[:source] ]]
      previous&.dig("usd_price")&.to_d
    end

    def previous_priced_assets
      @previous_priced_assets ||= Array(
        binance_item.binance_accounts
                    .find_by(account_type: "combined")
                    &.raw_payload&.dig("assets")
      ).select { |asset| asset["usd_price"].present? }
       .index_by { |asset| [ asset["symbol"], asset["source"] ] }
    end

    def upsert_binance_account(all_assets:, total_usd:, results:)
      ba = binance_item.binance_accounts.find_or_initialize_by(account_type: "combined")
      ba.name = binance_item.name if ba.new_record? || ba.name.blank?

      ba.assign_attributes(
        currency: "USD",
        current_balance: total_usd,
        institution_metadata: build_institution_metadata(all_assets),
        raw_payload: raw_by_source(results).merge(
          "assets" => all_assets.map(&:stringify_keys),
          "source_status" => source_status(results),
          "dust_omitted" => @dust_omitted,
          "unpriced_assets" => @unpriced_assets,
          "minimum_holding_usd" => MIN_HOLDING_USD.to_s("F"),
          "fetched_at" => Time.current.iso8601
        )
      )

      ba.save!
      ba
    end

    def build_institution_metadata(all_assets)
      all_assets.group_by { |asset| asset[:source_key] }.each_with_object({}) do |(source, source_assets), hash|
        hash[source] = {
          "asset_count" => source_assets.size,
          "assets" => source_assets.map { |asset| asset[:symbol] }.uniq
        }
      end
    end

    def raw_by_source(results)
      results.to_h { |result| [ result[:source], result[:raw] ] }
    end

    def snapshot_payload(results)
      raw_by_source(results).merge(
        "source_status" => source_status(results),
        "dust_omitted" => @dust_omitted,
        "unpriced_assets" => @unpriced_assets,
        "minimum_holding_usd" => MIN_HOLDING_USD.to_s("F"),
        "imported_at" => Time.current.iso8601
      )
    end

    def source_status(results)
      results.to_h do |result|
        status = if result[:error].present?
          { "status" => "unavailable", "error" => result[:error] }
        else
          { "status" => "ok", "asset_count" => result[:assets].size }
        end

        [ result[:source], status ]
      end
    end
end
