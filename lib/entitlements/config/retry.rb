# frozen_string_literal: true

require "retryable"

module Retry
  # This method should be called as early as possible in the startup of your application
  # It sets up the Retryable gem with custom contexts and passes through a few options
  # Should the number of retries be reached without success, the last exception will be raised
  def self.setup!
    ######## Retryable Configuration ########
    # All defaults available here:
    # https://github.com/nfedyashev/retryable/blob/6a04027e61607de559e15e48f281f3ccaa9750e8/lib/retryable/configuration.rb#L22-L33
    Retryable.configure do |config|
      config.contexts[:default] = {
        on: [StandardError],
        sleep: 1,
        tries: 3
      }
    end
  end
end
