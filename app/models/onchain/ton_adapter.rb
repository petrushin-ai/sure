# frozen_string_literal: true

# TON mainnet, read through TON Center API v3.
#
# The native balance is GRAM (nanograms on chain). Jettons are identified by
# their master contract, never by symbol. Metadata from an arbitrary master is
# display-only and never makes a token trusted; only the explicit master
# allowlist can preselect a Jetton in the review screen.
class Onchain::TonAdapter
  include Onchain::ChainAdapter

  NANOGRAMS_PER_GRAM = 1_000_000_000.to_d
  MAX_DECIMALS = 18
  GENESIS_START_UTIME = Time.utc(2018, 1, 1).to_i

  # Official TON documentation names this exact master as USDT. Identity is
  # still the master address; the immutable metadata below prevents a forged
  # symbol/name from being accepted for this allowlisted contract.
  TRUSTED_JETTONS = {
    "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe" => {
      symbol: "USDT",
      name: "Tether USD",
      decimals: 6
    }
  }.freeze

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    Onchain::TonAddress.valid?(address)
  end

  def canonical_address(address)
    Onchain::TonAddress.canonical(address) || address.to_s.strip
  end

  def fetch_snapshot(address)
    canonical = Onchain::TonAddress.canonical(address)
    raise Onchain::Chains::Error, "Invalid TON address" if canonical.nil?

    wrap_provider_errors do
      state = provider.account_state(canonical)
      wallet_page = provider.jetton_wallets(canonical, max_rows: Onchain::AssetBudget.tokens)
      token_assets = build_token_assets(wallet_page)

      ton_page = best_effort_movements do
        provider.ton_transfers(canonical, start_utime: history_start_utime, max_rows: history_row_budget)
      end
      jetton_page = best_effort_movements do
        provider.jetton_transfers(canonical, start_utime: history_start_utime, max_rows: history_row_budget)
      end

      movements = []
      movements.concat(native_movements(ton_page.rows, canonical)) if ton_page
      movements.concat(jetton_movements(jetton_page.rows, canonical, token_assets)) if jetton_page

      Onchain::Snapshot.new(
        assets: [ native_asset(state), *token_assets ],
        movements: movements.uniq(&:external_id),
        history_truncated: ton_page.nil? || jetton_page.nil? || ton_page.truncated || jetton_page.truncated,
        assets_truncated: wallet_page.truncated || @invalid_jetton_metadata
      )
    end
  end

  def provider_error_classes
    [ Provider::Toncenter::RateLimitError, Provider::Toncenter::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::TON)
    end

    def provider
      @provider ||= Provider::Toncenter.new(api_key: credentials[:toncenter_api_key])
    end

    def history_start_utime
      value = credentials[:sync_start_date]
      value.present? ? value.to_time.to_i : GENESIS_START_UTIME
    end

    def history_row_budget
      Onchain::HistoryBudget.pages * Onchain::HistoryBudget::PAGE_SIZE
    end

    def native_asset(state)
      raw_balance = state.to_h["balance"].presence || "0"
      definition.native_asset(quantity: decimal(raw_balance) / NANOGRAMS_PER_GRAM)
    end

    def build_token_assets(page)
      @invalid_jetton_metadata = false
      metadata = normalized_metadata(page.metadata)

      assets = page.rows.filter_map do |wallet|
        master = canonical_contract(wallet["jetton"])
        next if master.nil?

        trusted = TRUSTED_JETTONS[master]
        token_info = metadata_for(metadata, master)
        token = trusted || untrusted_metadata(master, token_info)
        next if token.nil?

        quantity = decimal(wallet["balance"]) / (10.to_d**token[:decimals])
        next if quantity.zero?

        definition.token_asset(
          symbol: token[:symbol],
          name: token[:name],
          decimals: token[:decimals],
          quantity: quantity,
          contract: master,
          notable: trusted.present?
        )
      end

      # An API page may theoretically repeat a master through stale duplicate
      # wallet rows. One master is one economic asset, so sum it once.
      assets
        .group_by(&:contract)
        .map do |_master, rows|
          first = rows.first
          first.with(quantity: rows.sum(&:quantity))
        end
        .sort_by { |asset| [ asset.notable? ? 0 : 1, asset.contract ] }
        .first(Onchain::AssetBudget.tokens)
    end

    def untrusted_metadata(master, token_info)
      decimals = integer_decimals(token_info&.dig("extra", "decimals"))
      unless decimals
        @invalid_jetton_metadata = true
        return nil
      end

      valid = token_info.to_h["valid"] == true
      safe = valid && token_info.to_h["is_scam"] != true && token_info.to_h["is_nsfw"] != true

      if safe
        {
          # A valid metadata document proves only that it was decoded, not that
          # this contract owns the ticker it claims. Keep the name for review,
          # mark it explicitly and use a non-priceable symbol until the master
          # is promoted into TRUSTED_JETTONS.
          symbol: placeholder_symbol(master),
          name: "#{token_info["name"].to_s.strip.presence || "Jetton #{master}"} (unverified)",
          decimals: decimals
        }
      else
        {
          symbol: placeholder_symbol(master),
          name: "Unverified Jetton #{master}",
          decimals: decimals
        }
      end
    end

    def integer_decimals(value)
      parsed = value.is_a?(Integer) ? value : Integer(value, 10)
      parsed if parsed.between?(0, MAX_DECIMALS)
    rescue ArgumentError, TypeError
      nil
    end

    def normalized_metadata(metadata)
      metadata.each_with_object({}) do |(address, entry), result|
        canonical = canonical_contract(address)
        result[canonical] = entry if canonical
      end
    end

    def metadata_for(metadata, master)
      Array(metadata.dig(master, "token_info")).find { |info| info["type"] == "jetton_masters" }
    end

    def native_movements(actions, address)
      actions.filter_map do |action|
        next unless action["success"] == true && action["finality"] == "finalized"
        next if action["action_id"].blank?

        details = action["details"].to_h
        amount = direction_amount(
          address,
          source: details["source"],
          destination: details["destination"],
          amount: decimal(details["value"]) / NANOGRAMS_PER_GRAM
        )
        next if amount.zero?

        timestamp = action["end_utime"] || action["start_utime"]
        next if timestamp.blank?

        Onchain::Movement.new(
          external_id: "ton_action_#{action["action_id"]}",
          symbol: definition.native.symbol,
          contract: nil,
          amount: amount,
          timestamp: Time.zone.at(timestamp.to_i)
        )
      end
    end

    def jetton_movements(transfers, address, assets)
      assets_by_master = assets.index_by(&:contract)

      transfers.filter_map do |transfer|
        next if transfer["transaction_aborted"] == true

        master = canonical_contract(transfer["jetton_master"])
        asset = assets_by_master[master]
        next if asset.nil?

        amount = direction_amount(
          address,
          source: transfer["source"],
          destination: transfer["destination"],
          amount: decimal(transfer["amount"]) / (10.to_d**asset.decimals)
        )
        next if amount.zero?

        timestamp = transfer["transaction_now"]
        next if timestamp.blank?

        Onchain::Movement.new(
          external_id: jetton_external_id(transfer, master),
          symbol: asset.symbol,
          contract: master,
          amount: amount,
          timestamp: Time.zone.at(timestamp.to_i)
        )
      end
    end

    def direction_amount(address, source:, destination:, amount:)
      source_address = canonical_contract(source)
      destination_address = canonical_contract(destination)
      return 0.to_d if source_address == address && destination_address == address
      return -amount if source_address == address
      return amount if destination_address == address

      0.to_d
    end

    def jetton_external_id(transfer, master)
      identity = [
        transfer["transaction_hash"], transfer["transaction_lt"], transfer["query_id"],
        master, transfer["source"], transfer["destination"], transfer["amount"]
      ].join(":")
      "ton_jetton_#{Digest::SHA256.hexdigest(identity)}"
    end

    def canonical_contract(address)
      Onchain::TonAddress.canonical(address)
    end

    def placeholder_symbol(master)
      hash = master.to_s.split(":", 2).last.to_s
      "JETTON:#{hash.first(4)}…#{hash.last(4)}"
    end

    def decimal(value)
      BigDecimal(value.to_s.presence || "0")
    rescue ArgumentError
      0.to_d
    end
end
