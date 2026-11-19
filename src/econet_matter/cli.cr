module EcoNetMatter
  module CLI
    DEFAULT_STORAGE    = "data/econet-matter.yml"
    POWER_FILE_MAX_AGE = 2.minutes

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

      client = EcoNet::Client.login(email, password)
      heater = select_heater(client, ENV["ECONET_SERIAL_NUMBER"]?)
      adapter = EcoNetHeater.new(client, heater)
      Dir.mkdir_p(File.dirname(storage_path), mode: 0o700)
      storage = Matter::Storage::YamlFile.new(storage_path)

      device = Device.new(adapter, storage, port: port, power_watts: meter)
      Process.on_terminate { device.shutdown! }
      Log.info { "Starting Matter for #{heater.device_name}" }
      device.start
      return 1 unless device.running?
      device.await_shutdown
      0
    rescue error : EcoNet::Error | Matter::Error | ArgumentError | IO::Error
      STDERR.puts "econet-matter: #{error.message}"
      1
    ensure
      storage.try &.close
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
