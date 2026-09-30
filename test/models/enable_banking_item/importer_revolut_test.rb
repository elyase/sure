require "test_helper"

class EnableBankingItem::ImporterRevolutTest < ActiveSupport::TestCase
  setup do
    family = families(:dylan_family)
    @account = family.accounts.create!(name: "Revolut test", currency: "EUR", balance: 0, accountable: Depository.new)
    @item = family.enable_banking_items.create!(
      name: "Revolut", aspsp_name: "Revolut", country_code: "DE",
      application_id: "test-app", client_certificate: "test-certificate",
      session_id: "test-session", session_expires_at: 1.day.from_now,
      sync_start_date: 1.month.ago.to_date
    )
    @provider_account = @item.enable_banking_accounts.create!(
      name: "Revolut test", uid: "test-account", account_id: "test-account", currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @provider_account)
    Setting.syncs_include_pending = false
    @provider = mock()
    @provider.stubs(:get_session).returns(accounts: [ @provider_account.uid ])
    @provider.stubs(:get_account_balances).returns(
      balances: [ { balance_type: "ITAV", balance_amount: { amount: "0", currency: "EUR" } } ]
    )
  end

  test "retains identical Revolut payments with distinct references across pages and repeat imports" do
    payment = { booking_date: Date.current.to_s, transaction_amount: { amount: "12.00", currency: "EUR" },
      creditor: { name: "Example shop" }, credit_debit_indicator: "DBIT", status: "BOOK" }
    first = payment.merge(entry_reference: "purchase-a")
    second = payment.merge(entry_reference: "purchase-b")
    @provider.stubs(:get_account_transactions).with(has_entry(continuation_key: nil))
      .returns(transactions: [ first ], continuation_key: "page-2")
    @provider.stubs(:get_account_transactions).with(has_entry(continuation_key: "page-2"))
      .returns(transactions: [ second, first.deep_dup ], continuation_key: nil)

    import_transactions
    assert_equal 2, @account.entries.count
    assert_equal 24.to_d, @account.entries.sum(:amount)
    assert_equal 2, @provider_account.reload.raw_transactions_payload.size
    ids = @account.entries.pluck(:id).sort

    @provider.unstub(:get_account_transactions)
    @provider.stubs(:get_account_transactions).returns(transactions: [ second, first ], continuation_key: nil)
    import_transactions
    assert_equal ids, @account.entries.pluck(:id).sort
    assert_equal 24.to_d, @account.entries.sum(:amount)
  end

  private
    def import_transactions
      result = EnableBankingItem::Importer.new(@item, enable_banking_provider: @provider).import
      assert result[:success], result.inspect
      result = EnableBankingAccount::Transactions::Processor.new(@provider_account.reload).process
      assert result[:success], result.inspect
    end
end
