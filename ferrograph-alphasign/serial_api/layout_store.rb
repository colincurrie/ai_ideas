require "json"
require "fileutils"

require_relative "layout"

module SerialApi
  # Keeps the layout on disk so a restart doesn't lose track of what the
  # sign is holding.
  #
  # This matters more here than it would elsewhere, because there is no way
  # to ask: XDF's read-back commands got no answer from real hardware, so
  # the sign cannot tell us what it has. This file is the only record.
  # Which also means it can be wrong - it says what we last *sent*, not
  # what is on the sign now - so it's written to be recoverable rather than
  # authoritative, and POST /resync exists for when the two have parted
  # company.
  class LayoutStore
    attr_reader :path, :last_error, :loaded_at

    def initialize(path)
      @path = path
      @last_error = nil
      @loaded_at = nil
    end

    def enabled?
      !@path.nil?
    end

    # Returns a Layout: the saved one if there is a readable file, an empty
    # one otherwise. Never raises - a corrupt or unreadable state file
    # shouldn't stop the service booting, when carrying on with an empty
    # layout costs nothing worse than a reconfiguration on the next write.
    def load
      return Layout.new unless enabled? && File.exist?(@path)

      state = JSON.parse(File.read(@path), symbolize_names: true)
      layout = Layout.from_state(state)
      @loaded_at = state[:saved_at]
      @last_error = nil
      layout
    rescue StandardError => e
      # Deliberately broad. The promise this method makes is that the
      # service always boots, and a state file can be wrong in more ways
      # than can be enumerated - truncated, valid JSON of the wrong shape,
      # written by a future version. Narrow rescues here were letting a
      # NoMethodError through from a file that parsed but wasn't a layout.
      @last_error = "couldn't read #{@path}: #{e.class}: #{e.message}"
      warn "serial_api: #{@last_error} - starting with an empty layout"
      Layout.new
    end

    # Written to a temporary file and renamed, so an interrupted save can't
    # leave a half-written file behind: rename is atomic within a
    # filesystem, so the file on disk is always one complete state or the
    # previous one.
    def save(layout)
      return unless enabled?

      FileUtils.mkdir_p(File.dirname(@path))
      temporary = "#{@path}.#{Process.pid}.tmp"
      File.write(temporary, JSON.pretty_generate(layout.to_state))
      File.rename(temporary, @path)
      @last_error = nil
      true
    rescue SystemCallError => e
      # A failed save must not fail the request: the write to the sign has
      # already happened and reporting it as an error would be a lie. Say
      # so in /status instead.
      @last_error = "couldn't write #{@path}: #{e.message}"
      warn "serial_api: #{@last_error}"
      false
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end

    def to_h
      { path: @path, enabled: enabled?, loaded_at: @loaded_at, error: @last_error }
    end
  end
end
