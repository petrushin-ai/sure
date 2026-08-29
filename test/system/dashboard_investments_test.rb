require "application_system_test_case"

class DashboardInvestmentsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.create!(
      owner: @user,
      name: "Edge Capital System",
      balance: 40_150,
      cash_balance: 40_150,
      currency: "USD",
      accountable: Investment.new
    )

    sign_in @user
  end

  test "mobile Investment widget scrolls internally and keeps values aligned" do
    page.current_window.resize_to(390, 844)
    visit root_path

    find("#investment-summary [data-investment-scroll-container]")
    find("#investment-summary [data-investment-account-id='#{@account.id}']")

    geometry = page.evaluate_script(<<~JS)
      (() => {
        const scrollContainer = document.querySelector("#investment-summary [data-investment-scroll-container]")
        const valueHeader = document.querySelector("#investment-summary [data-investment-column='value']")
        const accountValue = document.querySelector("#investment-summary [data-investment-account-id='#{@account.id}'] [data-investment-position-value]")
        const headerRect = valueHeader.getBoundingClientRect()
        const valueRect = accountValue.getBoundingClientRect()

        return {
          internalOverflow: scrollContainer.scrollWidth > scrollContainer.clientWidth,
          pageOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
          valueCenterDelta: Math.abs(
            (headerRect.left + headerRect.width / 2) - (valueRect.left + valueRect.width / 2)
          )
        }
      })()
    JS

    assert geometry.fetch("internalOverflow")
    assert_not geometry.fetch("pageOverflow")
    assert_operator geometry.fetch("valueCenterDelta"), :<=, 1
  ensure
    reset_viewport
  end
end
