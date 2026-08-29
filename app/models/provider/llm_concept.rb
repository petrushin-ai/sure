module Provider::LlmConcept
  extend ActiveSupport::Concern

  PDF_PROCESSING_EXTRACTED_DATA_KEYS = %w[
    institution_name
    statement_period_start
    statement_period_end
    transaction_count
    opening_balance
    closing_balance
    currency
    account_holder
  ].freeze

  def self.pdf_processing_json_schema
    {
      type: "object",
      properties: {
        document_type: {
          type: "string",
          enum: Import::DOCUMENT_TYPES,
          description: "Classification of the financial document."
        },
        summary: {
          type: "string",
          description: "Concise factual summary of the document."
        },
        extracted_data: {
          type: "object",
          properties: {
            institution_name: { type: [ "string", "null" ] },
            statement_period_start: { type: [ "string", "null" ], format: "date" },
            statement_period_end: { type: [ "string", "null" ], format: "date" },
            transaction_count: { type: [ "integer", "null" ], minimum: 0 },
            opening_balance: { type: [ "number", "null" ] },
            closing_balance: { type: [ "number", "null" ] },
            currency: { type: [ "string", "null" ] },
            account_holder: { type: [ "string", "null" ] }
          },
          required: PDF_PROCESSING_EXTRACTED_DATA_KEYS,
          additionalProperties: false
        }
      },
      required: %w[document_type summary extracted_data],
      additionalProperties: false
    }
  end

  def self.valid_pdf_processing_result?(result)
    return false unless result.is_a?(PdfProcessingResult)
    return false unless Import::DOCUMENT_TYPES.include?(result.document_type)
    return false unless result.summary.is_a?(String) && result.summary.present?
    return false unless result.extracted_data.is_a?(Hash)

    data = result.extracted_data.stringify_keys
    return false unless data.keys.sort == PDF_PROCESSING_EXTRACTED_DATA_KEYS.sort
    return false unless string_or_nil?(data["institution_name"])
    return false unless iso_date_or_nil?(data["statement_period_start"])
    return false unless iso_date_or_nil?(data["statement_period_end"])
    return false unless data["transaction_count"].nil? || data["transaction_count"].is_a?(Integer)
    return false if data["transaction_count"].is_a?(Integer) && data["transaction_count"].negative?
    return false unless data["opening_balance"].nil? || data["opening_balance"].is_a?(Numeric)
    return false unless data["closing_balance"].nil? || data["closing_balance"].is_a?(Numeric)
    return false unless string_or_nil?(data["currency"])
    return false unless string_or_nil?(data["account_holder"])

    true
  end

  def self.string_or_nil?(value)
    value.nil? || value.is_a?(String)
  end
  private_class_method :string_or_nil?

  def self.iso_date_or_nil?(value)
    return true if value.nil?
    return false unless value.is_a?(String)

    Date.iso8601(value)
    true
  rescue Date::Error
    false
  end
  private_class_method :iso_date_or_nil?

  AutoCategorization = Data.define(:transaction_id, :category_name)

  def auto_categorize(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_categorize"
  end

  AutoDetectedMerchant = Data.define(:transaction_id, :business_name, :business_url)

  def auto_detect_merchants(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_detect_merchants"
  end

  EnhancedMerchant = Data.define(:merchant_id, :business_url)

  def enhance_provider_merchants(merchants)
    raise NotImplementedError, "Subclasses must implement #enhance_provider_merchants"
  end

  PdfProcessingResult = Data.define(:summary, :document_type, :extracted_data)

  def supports_pdf_processing?
    false
  end

  def process_pdf(pdf_content:, family: nil)
    raise NotImplementedError, "Provider does not support PDF processing"
  end

  ChatMessage = Data.define(:id, :output_text)
  ChatStreamChunk = Data.define(:type, :data, :usage)
  ChatResponse = Data.define(:id, :model, :messages, :function_requests)
  ChatFunctionRequest = Data.define(:id, :call_id, :function_name, :function_args)

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil
  )
    raise NotImplementedError, "Subclasses must implement #chat_response"
  end
end
