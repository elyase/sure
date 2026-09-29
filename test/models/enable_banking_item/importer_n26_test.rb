require "test_helper"

class EnableBankingItem::ImporterN26Test < ActiveSupport::TestCase
  setup do
    family = families(:dylan_family)
    @account = family.accounts.create!(name: "N26 test", currency: "EUR", balance: 0, accountable: Depository.new)
    @item = family.enable_banking_items.create!(
      name: "N26", aspsp_name: "N26 Bank", country_code: "DE",
      application_id: "test-app", client_certificate: "test-certificate",
      session_id: "test-session", session_expires_at: 1.day.from_now,
      sync_start_date: 1.month.ago.to_date
    )
    @provider_account = @item.enable_banking_accounts.create!(
      name: "N26 test", uid: "test-account", account_id: "test-account", currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @provider_account)
    Setting.syncs_include_pending = false
    @provider = mock()
    @provider.stubs(:get_session).returns(accounts: [ @provider_account.uid ])
    @provider.stubs(:get_account_balances).returns(
      balances: [ { balance_type: "CLBD", balance_amount: { amount: "0", currency: "EUR" } } ]
    )
  end

  test "retains repeated ID-less payments across pages and repeat imports" do
    payment = payment()
    @provider.stubs(:get_account_transactions).with(has_entry(continuation_key: nil))
      .returns(transactions: [ payment ], continuation_key: "page-2")
    @provider.stubs(:get_account_transactions).with(has_entry(continuation_key: "page-2"))
      .returns(transactions: [ payment.deep_dup ], continuation_key: nil)

    import_transactions
    assert_equal 2, @account.entries.count
    assert_equal 24.to_d, @account.entries.sum(:amount)
    ids = @account.entries.pluck(:external_id).sort
    assert_includes ids, EnableBankingEntry::Processor.compute_external_id(payment)

    import_transactions
    assert_equal ids, @account.entries.pluck(:external_id).sort
    assert_equal 24.to_d, @account.entries.sum(:amount)
  end

  test "keeps a refund separate when its payment has the same reference" do
    debit = payment.merge(entry_reference: "shared-reference", booking_date: 10.days.ago.to_date.to_s)
    credit = payment.merge(entry_reference: "shared-reference", credit_debit_indicator: "CRDT")
    @provider.stubs(:get_account_transactions).returns(transactions: [ debit ], continuation_key: nil)
    import_transactions
    payment_id = @account.entries.sole.id

    # The original payment is outside the later response's window.
    @provider.stubs(:get_account_transactions).returns(transactions: [ credit ], continuation_key: nil)
    import_transactions
    assert_equal 2, @account.entries.count
    assert_equal 0.to_d, @account.entries.sum(:amount)
    assert_equal 12.to_d, @account.entries.find(payment_id).amount

    @provider.stubs(:get_account_transactions).returns(transactions: [ credit, debit ], continuation_key: nil)
    import_transactions
    assert_equal 2, @account.entries.count
    assert_equal 0.to_d, @account.entries.sum(:amount)
  end

  test "updates a settled payment under its existing reference without duplicating it" do
    original = payment.merge(entry_reference: "settling-payment")
    @provider.stubs(:get_account_transactions).returns(transactions: [ original ], continuation_key: nil)
    import_transactions
    id = @account.entries.sole.id

    settled = original.deep_merge(transaction_id: "late-bank-id", transaction_amount: { amount: "8.00" })
    @provider.stubs(:get_account_transactions).returns(transactions: [ settled ], continuation_key: nil)
    import_transactions
    assert_equal 1, @account.entries.count
    assert_equal 8.to_d, @account.entries.find(id).amount
  end

  test "does not discard identical payments carrying distinct bank references" do
    rows = [ payment.merge(entry_reference: "purchase-a"), payment.merge(entry_reference: "purchase-b") ]
    @provider.stubs(:get_account_transactions).returns(transactions: rows, continuation_key: nil)
    import_transactions
    ids = @account.entries.pluck(:id).sort
    assert_equal 2, ids.size
    @provider.stubs(:get_account_transactions).returns(transactions: rows.reverse, continuation_key: nil)
    import_transactions
    assert_equal ids, @account.entries.pluck(:id).sort
  end

  test "retains a legacy ID-less entry and adds only new occurrences" do
    row = payment
    @provider.stubs(:get_account_transactions).returns(transactions: [ row ], continuation_key: nil)
    import_transactions
    legacy_id = @account.entries.sole.id
    @provider_account.update!(raw_transactions_payload: [ row ])

    @provider.stubs(:get_account_transactions).returns(transactions: [ row, row.deep_dup, row.deep_dup ], continuation_key: nil)
    import_transactions
    assert_equal 3, @account.entries.count
    assert_equal 12.to_d, @account.entries.find(legacy_id).amount
    import_transactions
    assert_equal 3, @account.entries.count
    assert_equal 36.to_d, @account.entries.sum(:amount)
  end

  test "does not duplicate a repeated identified row" do
    row = payment.merge(entry_reference: "same-booking")
    @provider.stubs(:get_account_transactions).returns(transactions: [ row, row.deep_dup ], continuation_key: nil)
    import_transactions
    assert_equal 1, @account.entries.count
  end

  test "preserves import-locked entries when refreshing provider snapshots" do
    row = payment.merge(entry_reference: "locked-entry")
    @provider.stubs(:get_account_transactions).returns(transactions: [ row ], continuation_key: nil)
    import_transactions
    entry = @account.entries.sole
    entry.update!(import_locked: true, name: "User's verified description")
    changed = row.deep_merge(transaction_amount: { amount: "8.00" })
    @provider.stubs(:get_account_transactions).returns(transactions: [ changed ], continuation_key: nil)
    import_transactions
    assert_equal 12.to_d, entry.reload.amount
    assert_equal "User's verified description", entry.name
  end

  test "fails rather than silently merging conflicting same-reference bookings" do
    row = payment.merge(entry_reference: "ambiguous-reference")
    other = row.deep_merge(transaction_amount: { amount: "8.00" })
    @provider.stubs(:get_account_transactions).returns(transactions: [ row, other ], continuation_key: nil)
    result = EnableBankingItem::Importer.new(@item, enable_banking_provider: @provider).import
    assert_not result[:success]
    assert_empty @provider_account.reload.raw_transactions_payload.to_a
  end

  private
    def payment
      { booking_date: Date.current.to_s, transaction_amount: { amount: "12.00", currency: "EUR" },
        creditor: { name: "Example shop" }, credit_debit_indicator: "DBIT", status: "BOOK" }
    end

    def import_transactions
      result = EnableBankingItem::Importer.new(@item, enable_banking_provider: @provider).import
      assert result[:success], result.inspect
      result = EnableBankingAccount::Transactions::Processor.new(@provider_account.reload).process
      assert result[:success], result.inspect
    end
end
