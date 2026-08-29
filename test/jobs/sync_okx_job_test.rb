require "test_helper"

class SyncOkxJobTest < ActiveJob::TestCase
  test "stagger-enqueues each active connection" do
    family = families(:dylan_family)
    OkxItem.create!(family: family, name: "OKX A", api_key: "a", api_secret: "s", passphrase: "p")
    OkxItem.create!(family: family, name: "OKX B", api_key: "b", api_secret: "s", passphrase: "p")

    assert_enqueued_jobs 2, only: SyncOkxConnectionJob do
      SyncOkxJob.perform_now
    end
  end
end
