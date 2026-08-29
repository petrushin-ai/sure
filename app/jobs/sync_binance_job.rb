class SyncBinanceJob < ApplicationJob
  STAGGER_INTERVAL = 30.seconds
  MAX_STAGGER = 10.minutes

  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Rails.logger.info("Starting scheduled Binance sync")

    BinanceItem.active.find_each.with_index do |item, index|
      wait = [ index * STAGGER_INTERVAL, MAX_STAGGER ].min
      SyncBinanceConnectionJob.set(wait: wait).perform_later(item.id)
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Scheduled Binance connection sync could not be enqueued",
        source: self.class.name,
        provider_key: "binance",
        family: item.family,
        metadata: { binance_item_id: item.id, error_class: e.class.name, error: e.message }
      )
    end

    Rails.logger.info("Completed scheduled Binance sync")
  end
end
