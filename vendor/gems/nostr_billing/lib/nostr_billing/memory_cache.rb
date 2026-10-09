# frozen_string_literal: true

module NostrBilling
  # Minimal cache with the subset of the ActiveSupport::Cache interface the gate
  # uses (read, write with expires_in:, delete). For tests and non-Rails callers;
  # Rails apps pass Rails.cache.
  class MemoryCache
    def initialize(now: -> { Time.now.to_f })
      @now = now
      @data = {}
      @mutex = Mutex.new
    end

    def read(key)
      @mutex.synchronize do
        value, expires_at = @data[key]
        return nil if expires_at && expires_at <= @now.call

        value
      end
    end

    def write(key, value, expires_in: nil)
      @mutex.synchronize { @data[key] = [value, expires_in && @now.call + expires_in.to_f] }
      true
    end

    def delete(key)
      @mutex.synchronize { !@data.delete(key).nil? }
    end
  end
end
