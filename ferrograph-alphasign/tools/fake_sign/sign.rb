# frozen_string_literal: true

require_relative "decoder"

module FakeSign
  # A model of what the sign is holding, driven by decoded commands.
  #
  # Like the decoder, this is written from the XDF manual rather than from
  # serial_api's Layout - the point is to disagree when we're wrong.
  class Sign
    # Section 11: with the memory configuration cleared, XDF defines "one
    # Text file per available page ... File labels start at 'A' and will
    # increment for each page ... with 128K fitted, files 'A' to 'E' will
    # be defined, and with 256K fitted, the list will extend to 'K'."
    #
    # So which text labels exist by default depends on fitted memory, and
    # writing to a label outside that set fails on a sign that has never
    # been given a configuration. Default here is a 128K machine.
    PAGES_BY_MEMORY = { 128 => 5, 256 => 11 }.freeze

    DISPLAY_WIDTH = 135
    DISPLAY_HEIGHT = 16

    attr_reader :files, :findings, :memory_kb

    def initialize(memory_kb: 128)
      @memory_kb = memory_kb
      @findings = []
      reset_to_default_configuration
    end

    def reset_to_default_configuration
      pages = PAGES_BY_MEMORY.fetch(@memory_kb) { PAGES_BY_MEMORY[128] }
      @configured = false
      @files = {}
      pages.times do |i|
        label = ("A".ord + i).chr
        @files[label] = { type: :text, size: 20_480, content: nil, updated: false }
      end
    end

    # Applies one decoded command. Returns the findings it produced - the
    # decoder's own, plus anything only a stateful view can see (writing to
    # a label no configuration defines, say).
    def apply(command)
      produced = command.findings.dup
      case command.kind
      when :memory_config then apply_memory_config(command, produced)
      when :write_text then apply_write(command, :text, produced)
      when :write_string then apply_write(command, :string, produced)
      when :write_dots then apply_write(command, :dots, produced)
      end
      @findings.concat(produced)
      produced
    end

    # Section 11: defining memory "will erase any existing memory
    # configuration" and every file with it. This is the behaviour that
    # made sending a picture blank the display.
    def apply_memory_config(command, produced)
      entries = command.fields[:entries] || []
      return if entries.empty? && !command.ok?

      @configured = true
      @files = {}
      entries.each do |entry|
        @files[entry[:label]] = {
          type: entry[:type], size: entry[:size], updated: false, content: nil,
          height: entry[:height], width: entry[:width], depth: entry[:depth]
        }.compact
      end
      produced << Finding.new(severity: :warning, offset: 0,
                              message: "memory configured: every file's contents erased, #{entries.size} file(s) defined")
    end

    def apply_write(command, type, produced)
      label = command.fields[:label]
      return if label.nil?

      file = @files[label]
      if file.nil?
        # Section 6: XDF reports a failure to find or allocate the file via
        # the "Parity Error" bit of the serial error status.
        produced << Finding.new(
          severity: :error, offset: 0,
          message: "no file #{label.inspect} is defined, so this write is dropped " \
                   "(the sign flags a memory allocation failure). #{defined_labels_hint}"
        )
        return
      end

      if file[:type] != type
        produced << Finding.new(severity: :error, offset: 0,
                                message: "file #{label.inspect} is defined as a #{file[:type]} file, but this is a #{type} write")
        return
      end

      if type == :dots
        declared_height = file[:height]
        declared_width = file[:width]
        if declared_height && (declared_height != command.fields[:height] || declared_width != command.fields[:width])
          produced << Finding.new(
            severity: :error, offset: 0,
            message: "picture is #{command.fields[:width]}x#{command.fields[:height]} but the configuration " \
                     "reserved #{declared_width}x#{declared_height} for #{label.inspect} - the sign only allocated room for the latter"
          )
          return # rejected, so don't record it as the file's contents
        end
      end

      file[:content] = command.fields
      file[:updated] = true
    end

    def defined_labels_hint
      if @configured
        "Defined: #{@files.keys.sort.join(', ')}."
      else
        "No configuration has been sent, so the sign is on its default layout: " \
          "one text file per memory page, #{@files.keys.sort.join(', ')} on a #{@memory_kb}K machine."
      end
    end

    # Text files are the run sequence; strings and pictures only appear
    # where a text file calls them.
    def run_sequence
      @files.select { |_, f| f[:type] == :text && f[:updated] }.keys.sort
    end

    def to_h
      {
        configured: @configured,
        memory_kb: @memory_kb,
        display: { width: DISPLAY_WIDTH, height: DISPLAY_HEIGHT },
        run_sequence: run_sequence,
        files: @files.transform_values do |file|
          summary = { type: file[:type], updated: file[:updated] }
          summary[:size] = file[:size] if file[:size]
          if file[:type] == :dots && file[:height]
            summary[:dimensions] = "#{file[:width]}x#{file[:height]}"
          end
          summary[:preview] = preview_of(file)
          summary
        end
      }
    end

    def preview_of(file)
      return nil unless file[:updated]

      case file[:type]
      when :text, :string
        (file[:content][:content] || []).map do |run|
          case run[:type]
          when :text then run[:value]
          when :call_string then "[string #{run[:label]}]"
          when :call_dots then "[image #{run[:label]}]"
          when :colour then "[#{run[:value]} colour]"
          when :charset then "[font #{run[:value]}]"
          else "[#{run[:type]}]"
          end
        end.join
      when :dots
        "#{file[:content][:width]}x#{file[:content][:height]} picture"
      end
    end
  end
end
