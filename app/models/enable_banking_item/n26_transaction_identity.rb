class EnableBankingItem::N26TransactionIdentity
  class AmbiguousReferenceError < StandardError; end

  # N26 can return several real booked payments with identical contents and no
  # identifiers. Preserve their multiplicity within the complete paginated
  # response. The first occurrence retains the legacy ID for existing ledgers.
  def self.normalize(transactions, existing: [])
    # A reference is not permission to drop conflicting booked rows. Stop the
    # import if one response asserts different movements under the same identity.
    transactions.group_by { |tx| reference_key(tx.with_indifferent_access) }.each do |key, group|
      next unless key
      movements = group.map do |transaction|
        data = transaction.with_indifferent_access
        [ data[:booking_date].presence || data[:value_date].presence || data[:transaction_date],
          data.dig(:transaction_amount, :amount).to_d, data.dig(:transaction_amount, :currency) ]
      end
      if movements.uniq.size > 1
        raise AmbiguousReferenceError, "N26 returned conflicting movements with the same reference and direction"
      end
    end

    occurrences = Hash.new(0)
    references = existing.each_with_object({}) do |transaction, ids|
      data = transaction.with_indifferent_access
      key = reference_key(data)
      ids[key] = EnableBankingEntry::Processor.compute_external_id(data) if key
    end
    used_ids = references.values.to_set
    seen_references = Set.new

    # A refund can share the payment's reference. Reuse existing identities so
    # a later window containing only the refund cannot overwrite the payment.
    transactions.map { |tx| reference_key(tx.with_indifferent_access) }.compact.uniq.sort.each do |key|
      next if references[key]
      candidate = "enable_banking_#{key.first}"
      candidate = "#{candidate}_#{key.last}" if used_ids.include?(candidate)
      references[key] = candidate
      used_ids << candidate
    end

    transactions.filter_map do |transaction|
      data = transaction.with_indifferent_access.except(:_sure_external_id)
      key = reference_key(data)
      if key
        next if seen_references.include?(key)
        seen_references << key
        next data.merge(_sure_external_id: references.fetch(key))
      end

      base_id = EnableBankingEntry::Processor.compute_external_id(data)
      next data if base_id.nil?

      occurrences[base_id] += 1
      ordinal = occurrences[base_id]
      data.merge(_sure_external_id: ordinal == 1 ? base_id : "#{base_id}_occurrence_#{ordinal}")
    end
  end

  def self.reference_key(data)
    reference = data[:entry_reference].presence || data[:transaction_id].presence
    [ reference, data[:credit_debit_indicator].to_s ] if reference
  end
  private_class_method :reference_key
end
