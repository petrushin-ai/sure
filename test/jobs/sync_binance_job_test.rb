require "test_helper"

class SyncBinanceJobTest < ActiveJob::TestCase
  test "schedules every active Binance connection with bounded staggering" do
    active_items = BinanceItem.active.order(:id).to_a

    assert_enqueued_jobs active_items.size, only: SyncBinanceConnectionJob do
      SyncBinanceJob.perform_now
    end

    jobs = enqueued_jobs.select { |job| job[:job] == SyncBinanceConnectionJob }
    assert_equal active_items.map(&:id).sort, jobs.map { |job| job[:args].first }.sort
    assert jobs.all? { |job| job[:at].present? }
    assert_operator jobs.map { |job| job[:at] }.max - jobs.map { |job| job[:at] }.min,
                    :<=,
                    SyncBinanceJob::MAX_STAGGER.to_f + 1
  end

  test "records an enqueue failure and continues" do
    family = families(:dylan_family)
    failing = stub(id: "failed-id", family: family)
    success = stub(id: "successful-id", family: family)

    relation = mock("active_binance_items")
    relation.stubs(:find_each).returns([ failing, success ].each)
    BinanceItem.expects(:active).returns(relation)

    scheduled = mock("scheduled_binance_job")
    SyncBinanceConnectionJob.stubs(:set).returns(scheduled)
    scheduled.expects(:perform_later).with("failed-id").raises(StandardError, "queue unavailable")
    scheduled.expects(:perform_later).with("successful-id").returns(true)

    assert_difference "DebugLogEntry.count", 1 do
      SyncBinanceJob.perform_now
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "binance", entry.provider_key
    assert_equal "failed-id", entry.metadata["binance_item_id"]
  end
end
