# frozen_string_literal: true

require "pty"
require "json"
require "sinatra/base"

require_relative "decoder"
require_relative "sign"
require_relative "renderer"

module FakeSign
  # A stand-in for the sign: opens a pseudo-terminal that serial_api (or
  # bin/alphasign) can talk to exactly as it talks to the real thing,
  # decodes what arrives, and serves a live preview.
  #
  # It deliberately does NOT answer read requests. The reply formats come
  # from Alpha's protocol manual rather than XDF's, so answering would mean
  # inventing both halves of a conversation and then testing one against
  # the other - the exact circularity this whole tool exists to avoid. It
  # logs the request and says so.
  class Server < Sinatra::Base
    set :public_folder, File.join(__dir__, "public")
    set :views, File.join(__dir__, "views")
    set :host_authorization, permitted_hosts: []
    set :show_exceptions, false

    class << self
      attr_accessor :sign, :log, :device, :mutex
    end

    def self.boot!(memory_kb: 128)
      self.sign = Sign.new(memory_kb: memory_kb)
      self.log = []
      self.mutex = Mutex.new
      master, slave = PTY.open
      self.device = slave.path
      Thread.new { pump(master) }
      [master, slave]
    end

    # Reads the wire forever, decoding as bytes arrive.
    def self.pump(master)
      decoder = Decoder.new
      loop do
        begin
          data = master.readpartial(4096)
        rescue EOFError, Errno::EIO
          sleep 0.05
          next
        end

        decoder.feed(data).each do |command|
          findings = sign.apply(command)
          mutex.synchronize do
            log.unshift(entry_for(command, findings))
            log.pop while log.size > 200
          end
        end
      end
    end

    def self.entry_for(command, findings)
      {
        at: Time.now.strftime("%H:%M:%S"),
        kind: command.kind,
        summary: summarise(command),
        bytes: command.raw.bytes.map { |b| format("%02X", b) }.join(" "),
        findings: findings.map { |f| { severity: f.severity, message: f.message, offset: f.offset } }
      }
    end

    def self.summarise(command)
      f = command.fields
      case command.kind
      when :write_text then "write text #{f[:label]} (#{f[:position]}, effect #{f[:effect]})"
      when :write_string then "write string #{f[:label]}"
      when :write_dots then "write picture #{f[:label]} #{f[:width]}x#{f[:height]}"
      when :memory_config then "configure memory: #{(f[:entries] || []).map { |e| "#{e[:label]}(#{e[:type]})" }.join(' ')}"
      when :read_request then "read request #{f[:command]}#{f[:payload]} - not answered (see tools/fake_sign/README.md)"
      else command.kind.to_s
      end
    end

    get "/" do
      erb :index
    end

    get "/state" do
      content_type :json
      self.class.mutex.synchronize do
        {
          device: self.class.device,
          sign: self.class.sign.to_h,
          frames: Renderer.new(self.class.sign).frames,
          log: self.class.log.first(50)
        }.to_json
      end
    end

    post "/reset" do
      content_type :json
      self.class.mutex.synchronize do
        self.class.sign.reset_to_default_configuration
        self.class.log.clear
      end
      { ok: true }.to_json
    end
  end
end
