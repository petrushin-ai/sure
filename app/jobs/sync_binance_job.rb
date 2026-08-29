class SyncBinanceJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Rails.logger.info("Starting scheduled Binance sync")

    BinanceItem.active.find_each do |item|
      item.sync_later
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Scheduled Binance sync could not be enqueued",
        source: self.class.name,
        provider_key: "binance",
        family: item.family,
        metadata: { binance_item_id: item.id, error_class: e.class.name, error: e.message }
      )
    end

    Rails.logger.info("Completed scheduled Binance sync")
  end
end
