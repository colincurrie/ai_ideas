require "net/http"
require "json"
require "uri"

module WebApp
  # A small HTTP client for the serial-api service. Kept deliberately
  # dependency-free (stdlib Net::HTTP only) since this is the only thing
  # web_app needs to talk to serial-api - there's no reason to pull in a
  # full HTTP client gem for that.
  class SerialApiClient
    def initialize(base_url)
      @base = URI.parse(base_url)
    end

    def get(path)
      request(Net::HTTP::Get.new(full_path(path)))
    end

    def post(path, body)
      req = Net::HTTP::Post.new(full_path(path), "Content-Type" => "application/json")
      req.body = body.to_json
      request(req)
    end

    def delete(path)
      request(Net::HTTP::Delete.new(full_path(path)))
    end

    private

    def full_path(path)
      @base.path.to_s + path
    end

    def request(req)
      http = Net::HTTP.new(@base.host, @base.port)
      # Generous on purpose: a full-size image at the slowest supported baud
      # (2400) can take ~10s just to transmit the pixel data, plus serial_api's
      # deliberate 1s pause between the memory-config and picture-data writes.
      http.read_timeout = 30
      http.open_timeout = 3
      res = http.request(req)
      body = res.body.to_s.empty? ? {} : JSON.parse(res.body, symbolize_names: true)
      [res.code.to_i, body]
    rescue StandardError => e
      [502, { ok: false, error: "serial-api unreachable: #{e.message}" }]
    end
  end
end
