module EcoNetMatter
  module CLI
    DEFAULT_STORAGE    = "data/econet-matter.yml"
    POWER_FILE_MAX_AGE = 2.minutes

    private STARTUP_RETRY_DELAY     = 5.seconds
    private RATE_LIMIT_RETRY_DELAY  = 1.minute
    private MAX_STARTUP_RETRY_DELAY = 5.minutes

    HELP = <<-TEXT
      Usage: econet-matter

      Required environment variables
        ECONET_EMAIL            EcoNet account email
        ECONET_PASSWORD         EcoNet account password

      Optional environment variables
        ECONET_SERIAL_NUMBER    Water heater serial number for accounts with multiple heaters
        MATTER_STORAGE_FILE     Pairing and energy state (default: #{DEFAULT_STORAGE})
        MATTER_PORT             UDP port (default: #{Matter::Device::DEFAULT_PORT})
        ECONET_POWER_FILE       File containing current real power in watts
        LOG_LEVEL               Minimum log level (default: info)
      TEXT

    def self.run : Int32
      if ARGV == ["--help"] || ARGV == ["-h"]
        puts HELP
        return 0
      end
      raise ArgumentError.new("Use --help for configuration") unless ARGV.empty?

      backend = ::Log::IOBackend.new
      ::Log.setup(::Log::Severity.parse(ENV["LOG_LEVEL"]? || "info"), backend)
      # The MQTT shard's debug output can contain authentication packet fields.
      ::Log.setup("mqtt", :warn, backend)

      email = required_env("ECONET_EMAIL")
      password = required_env("ECONET_PASSWORD")
      storage_path = ENV["MATTER_STORAGE_FILE"]? || DEFAULT_STORAGE
      port = parse_port(ENV["MATTER_PORT"]?)
      meter = power_reader(ENV["ECONET_POWER_FILE"]?)
      serial = ENV["ECONET_SERIAL_NUMBER"]?

      stop = Channel(Nil).new
      Process.on_terminate { stop.close }
      connection = connect_with_backoff(stop) do
        client = EcoNet::Client.login(email, password)
        return 0 if stop.closed?
        {client, select_heater(client, serial)}
      end
      return 0 if stop.closed? || connection.nil?
      client, heater = connection
      adapter = EcoNetHeater.new(client, heater)
      Dir.mkdir_p(File.dirname(storage_path), mode: 0o700)
      storage = Matter::Storage::YamlFile.new(storage_path)

      device = Device.new(adapter, storage, port: port, power_watts: meter)
      if stop.closed?
        device.shutdown!
        return 0
      end
      Log.info { "Starting Matter for #{heater.device_name}" }
      device.start
      return stop.closed? ? 0 : 1 unless device.running?
      spawn do
        stop.receive?
        device.shutdown!
      end
      device.await_shutdown
      0
    rescue error : EcoNet::InvalidCredentialsError | ArgumentError
      STDERR.puts "econet-matter: #{error.message}"
      return 1 unless stop

      # Keep the container from restarting and authenticating with the same settings.
      STDERR.puts "econet-matter: Startup paused. Correct the configuration and restart."
      stop.receive?
      0
    rescue error : EcoNet::Error | Matter::Error | IO::Error
      STDERR.puts "econet-matter: #{error.message}"
      1
    ensure
      stop.try &.close
      storage.try &.close
    end

    private def self.connect_with_backoff(stop : Channel(Nil), &)
      delay = STARTUP_RETRY_DELAY
      until stop.closed?
        begin
          return yield
        rescue error : EcoNet::InvalidCredentialsError
          raise error
        rescue error : EcoNet::Error
          if error.is_a?(EcoNet::GenericHTTPError) && error.status_code == 429
            delay = Math.max(delay, RATE_LIMIT_RETRY_DELAY)
          end
          STDERR.puts "econet-matter: #{error.message}. Retrying in #{delay.total_seconds.to_i}s."
          select
          when stop.receive?
            break
          when timeout(delay)
            delay = Math.min(delay * 2, MAX_STARTUP_RETRY_DELAY)
          end
        end
      end
      nil
    end

    private def self.required_env(key : String) : String
      value = ENV[key]?
      raise ArgumentError.new("#{key} is required") if value.nil? || value.empty?
      value
    end

    private def self.parse_port(text : String?) : Int32
      return Matter::Device::DEFAULT_PORT unless text
      port = text.to_i?
      raise ArgumentError.new("MATTER_PORT must be an integer between 0 and 65535") unless port && 0 <= port <= UInt16::MAX
      port
    end

    private def self.select_heater(client : EcoNet::Client, serial : String?) : EcoNet::WaterHeater
      heaters = client.get_equipment.compact_map(&.as?(EcoNet::WaterHeater))
      if serial
        heaters.find { |heater| heater.serial_number == serial } ||
          raise ArgumentError.new("ECONET_SERIAL_NUMBER did not match an EcoNet water heater")
      elsif heaters.size == 1
        heaters.first
      elsif heaters.empty?
        raise ArgumentError.new("The EcoNet account has no water heaters")
      else
        raise ArgumentError.new("Set ECONET_SERIAL_NUMBER to select one of the account's water heaters")
      end
    end

    private def self.power_reader(path : String?) : Proc(Float64?)?
      return unless path
      -> : Float64? {
        info = File.info?(path)
        if info && info.file? && (Time.utc - info.modification_time) <= POWER_FILE_MAX_AGE
          File.read(path).strip.to_f64?
        end
      }
    end
  end
end
