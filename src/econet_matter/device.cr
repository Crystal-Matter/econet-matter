module EcoNetMatter
  class Device < Matter::Device
    WATER_HEATER_ENDPOINT = 1_u16
    THERMOSTAT_ENDPOINT   = 2_u16
    ELECTRICAL_ENDPOINT   = 3_u16

    WATER_HEATER_TYPE = 0x050F_u32
    ELECTRICAL_TYPE   = 0x0510_u32
    TYPE_REVISION     =      1_u16

    VENDOR_ID  = Matter::SetupPayload::TEST_VENDOR_ID_MINIMUM
    PRODUCT_ID = 0xE001_u16

    POLL_TICK       = 5.seconds
    REFRESH_PERIOD  = 1.minute
    ENERGY_PERIOD   = 5.minutes
    MW_PER_WATT     =           1_000
    MAX_POWER_MW    = 100_000_000_i64
    VACATION_ID     =            0_u8
    VENDOR_TAG_BASE =      0x8000_u16

    STORAGE_COLLECTION = Energy::COLLECTION
    IDENTITY_RECORD    = "identity"
    HEAT_MODE_RECORD   = "heating_mode"
    BOOST_RECORD       = "boost"

    alias Management = Matter::Cluster::WaterHeaterManagement
    alias WaterMode = Matter::Cluster::WaterHeaterMode
    alias Power = Matter::Cluster::ElectricalPowerMeasurement
    alias Topology = Matter::Cluster::PowerTopology
    alias Descriptor = Matter::Cluster::Descriptor
    alias SystemMode = Matter::Cluster::Thermostat::SystemMode

    getter heater_thermostat : Thermostat
    getter home_thermostat : Thermostat
    getter management : Management
    getter water_mode : WaterMode
    getter power : Power
    getter electrical_energy : Energy::Cluster
    getter energy : Energy

    @commands = Mutex.new
    @stop = Channel(Nil).new
    @worker_done : Channel(Nil)? = nil
    @shutdown_started = Atomic(Bool).new(false)
    @boost_previous : Mode? = nil
    @boost_target : Mode? = nil
    @boost_confirmed = false
    @identity : Tuple(UInt16, UInt32, String)
    @thermostats : Tuple(Thermostat, Thermostat)
    @clusters : Array(Matter::Cluster::Base)
    @mode_choices : Hash(UInt8, Mode)
    @heat_mode : Mode
    @reported_running : Bool
    @current_mode_id : UInt8

    def initialize(@heater : Heater, @storage : Matter::Storage::Backend,
                   *, port : Int32 = Matter::Device::DEFAULT_PORT,
                   ip_addresses : Array(Socket::IPAddress)? = nil,
                   @power_watts : Proc(Float64?)? = nil)
      options = @heater.modes
      unless options.includes?(Mode::Vacation)
        raise ArgumentError.new("The EcoNet heater must advertise a Vacation or Holiday mode")
      end
      active = options.select { |mode| heating_mode?(mode) }.uniq!
      raise ArgumentError.new("The EcoNet heater has no supported heating mode") if active.empty?
      @mode_choices = {VACATION_ID => Mode::Vacation}
      options.each do |mode|
        next if mode.in?(Mode::Unknown, Mode::Off, Mode::Vacation)
        @mode_choices[mode.value.to_u8] = mode
      end

      state = @heater.state
      @reported_running = state.running
      matter_limits, target = initial_temperature(state)
      @storage.open
      @identity = load_identity
      @boost_previous = read_mode(BOOST_RECORD, "previous")
      @boost_target = read_mode(BOOST_RECORD, "target")
      @heat_mode = initial_heat_mode(active, @boost_previous || state.mode)
      @current_mode_id = mode_id(state.mode) || @heat_mode.value.to_u8

      write_mode = ->(mode : SystemMode) { change_system_mode(mode) }
      write_setpoint = ->(value : Int16) { change_setpoint(value) }
      @heater_thermostat = Thermostat.new(WATER_HEATER_ENDPOINT, matter_limits, target, write_mode, write_setpoint)
      @home_thermostat = Thermostat.new(THERMOSTAT_ENDPOINT, matter_limits, target, write_mode, write_setpoint)
      @thermostats = {@heater_thermostat, @home_thermostat}

      heater_endpoint = Matter::DataType::EndpointNumber.new(WATER_HEATER_ENDPOINT)
      thermostat_endpoint = Matter::DataType::EndpointNumber.new(THERMOSTAT_ENDPOINT)
      electrical_endpoint = Matter::DataType::EndpointNumber.new(ELECTRICAL_ENDPOINT)
      tank = state.hot_water_percentage
      @management = Management.new(heater_endpoint, heater_types: @heater.heater_types,
        feature_map: tank ? Management::Feature::TankPercent : Management::Feature::None,
        tank_percentage: tank.try(&.clamp(0, 100).to_u8) || 0_u8)
      @water_mode = WaterMode.new(heater_endpoint, mode_options, @current_mode_id)
      @power = Power.new(electrical_endpoint, feature_map: Power::Feature::AlternatingCurrent,
        power_mode: Power::PowerMode::AC,
        accuracy: [accuracy(Power::MeasurementType::ActivePower, MAX_POWER_MW)])
      @electrical_energy = Energy::Cluster.new(electrical_endpoint,
        feature_map: Energy::Cluster::Feature::ImportedEnergy | Energy::Cluster::Feature::PeriodicEnergy | Energy::Cluster::Feature::CumulativeEnergy,
        accuracy: accuracy(Power::MeasurementType::ElectricalEnergy, Energy::Measurement::MEASUREMENT_LIMIT))

      @clusters = [
        @heater_thermostat, @management, @water_mode, @home_thermostat,
        Matter::Cluster::Identify.new(thermostat_endpoint),
        Matter::Cluster::Groups.new(thermostat_endpoint),
        @power, @electrical_energy,
        Topology.new(electrical_endpoint, feature_map: Topology::Feature::SetTopology,
          available_endpoints: [WATER_HEATER_ENDPOINT, THERMOSTAT_ENDPOINT]),
      ] of Matter::Cluster::Base
      @energy = Energy.new(@storage, @electrical_energy)

      super(@storage, ip_addresses: ip_addresses, port: port)

      @water_mode.on_change_to_mode { |id| change_water_mode(id) }
      @management.on_boost { |info| start_boost(info) }
      @management.on_cancel_boost { cancel_boost }
      reconcile
    end

    def device_name : String
      "EcoNet Water Heater"
    end

    def vendor_id : UInt16
      VENDOR_ID
    end

    def product_id : UInt16
      PRODUCT_ID
    end

    def discriminator : UInt16
      @identity[0]
    end

    def setup_pin : UInt32
      @identity[1]
    end

    def unique_id : String
      @identity[2]
    end

    # Advertise the thermostat hint for Apple Home. Descriptor carries the
    # actual type of every endpoint, including the native water heater.
    def primary_device_type_id : UInt32
      Matter::DeviceType::THERMOSTAT
    end

    def running? : Bool
      !@worker_done.nil? && !@stop.closed?
    end

    protected def device_clusters : Array(Matter::Cluster::Base)
      @clusters
    end

    protected def endpoint_device_types : Hash(UInt16, UInt32)
      {
        WATER_HEATER_ENDPOINT => WATER_HEATER_TYPE,
        THERMOSTAT_ENDPOINT   => Matter::DeviceType::THERMOSTAT,
        ELECTRICAL_ENDPOINT   => ELECTRICAL_TYPE,
      }
    end

    protected def endpoint_compositions : Hash(UInt16, Tuple(UInt16, Array(Descriptor::SemanticTag)))
      {ELECTRICAL_ENDPOINT => {WATER_HEATER_ENDPOINT, [] of Descriptor::SemanticTag}}
    end

    # The develop branch implements both sets of clusters. Its device type
    # registry has yet to list these two types, so supply their definitions here.
    private def device_types_for(endpoint_id : UInt16, declared_types : Hash(UInt16, UInt32)) : Array(Matter::DeviceType)
      case endpoint_id
      when WATER_HEATER_ENDPOINT
        [Matter::DeviceType.new(Matter::DataType::DeviceTypeId.new(WATER_HEATER_TYPE), "Water Heater", TYPE_REVISION,
          required_server_clusters: [Descriptor::CLUSTER_ID, Management::CLUSTER_ID, WaterMode::CLUSTER_ID, Thermostat::CLUSTER_ID],
          required_server_features: {Thermostat::CLUSTER_ID => Thermostat::Feature::Heating.value})]
      when ELECTRICAL_ENDPOINT
        [Matter::DeviceType.new(Matter::DataType::DeviceTypeId.new(ELECTRICAL_TYPE), "Electrical Sensor", TYPE_REVISION,
          required_server_clusters: [Descriptor::CLUSTER_ID, Topology::CLUSTER_ID, Power::CLUSTER_ID, Energy::Cluster::CLUSTER_ID])]
      else
        super
      end
    end

    def setup_code : String
      Matter::SetupPayload.generate_manual_code(discriminator, setup_pin)
    end

    def qr_code_payload : String
      Matter::SetupPayload::QRCode.generate_qr_code(
        discriminator, setup_pin, vendor_id, product_id,
        capabilities: Matter::SetupPayload::QRCode::DiscoveryCapability::OnNetwork)
    end

    protected def started_commissioning_mode : Nil
      payload = qr_code_payload
      puts "Matter QR payload: #{payload}"
      puts "Matter manual pairing code: #{setup_code}"
      Goban::QR.encode_string(payload, Goban::ECC::Level::Low).print_to_console if STDOUT.tty?
      STDOUT.flush
    end

    protected def started_operational_mode : Nil
      Log.info { "Matter node is commissioned on #{fabric_table.size} fabric(s)" }
    end

    protected def on_started : Nil
      done = Channel(Nil).new
      @worker_done = done
      spawn do
        poll
      ensure
        done.close
      end
    end

    def shutdown! : Nil
      return if @shutdown_started.swap(true)
      begin
        @stop.close
        @worker_done.try(&.receive?)
        result = cancel_boost(stopping: true)
        Log.warn { "The saved heater mode will be restored on restart" } unless result.success?
      rescue error
        Log.warn { "EcoNet shutdown failed (#{error.class})" }
      ensure
        begin
          @heater.close
        ensure
          super
        end
      end
    end

    # Apply EcoNet-reported state to the two views without publishing a command.
    def reconcile : Nil
      @commands.synchronize do
        return if @stop.closed?
        state = @heater.state
        @reported_running = state.running
        reconcile_boost(state.mode)
        if id = mode_id(state.mode)
          @current_mode_id = id
          if heating_mode?(state.mode) && @boost_previous.nil?
            remember_mode(state.mode)
          end
        end
        report_mode(@current_mode_id)
        if target = state.set_point_celsius
          if target.finite? && -50 <= target <= 100
            report_setpoint(Thermostat.centi_degrees(target))
          end
        end
        report_heat_demand(state)
        if @management.feature_map.tank_percent? && (percent = state.hot_water_percentage)
          @management.report_tank_percentage(percent.clamp(0, 100).to_u8)
        end
      end
    end

    private def initial_temperature(state : HeaterState) : Tuple(Tuple(Int16, Int16), Int16)
      min_temp, max_temp = @heater.limits_celsius || raise ArgumentError.new("EcoNet did not supply temperature limits")
      unless min_temp.finite? && max_temp.finite? && -50 <= min_temp <= max_temp <= 100
        raise ArgumentError.new("EcoNet supplied invalid temperature limits")
      end
      target = state.set_point_celsius || raise ArgumentError.new("EcoNet did not supply a target temperature")
      raise ArgumentError.new("EcoNet supplied an invalid target temperature") unless target.finite?
      limits = {Thermostat.centi_degrees(min_temp), Thermostat.centi_degrees(max_temp)}
      {limits, Thermostat.centi_degrees(target.clamp(min_temp, max_temp))}
    end

    private def initial_heat_mode(active : Array(Mode), current : Mode) : Mode
      return current if active.includes?(current)
      saved = read_mode(HEAT_MODE_RECORD, "mode")
      return saved if saved && active.includes?(saved)
      [Mode::Default, Mode::EnergySaving, Mode::HeatPumpOnly].find { |mode| active.includes?(mode) } || active.first
    end

    private def reconcile_boost(mode : Mode) : Nil
      return unless @boost_previous
      if mode == @boost_target
        @boost_confirmed = true
      elsif @boost_confirmed && !mode.unknown?
        clear_boost
      end
    end

    private def change_system_mode(mode : SystemMode) : Status
      @commands.synchronize do
        target = mode.off? ? Mode::Vacation : @heat_mode
        if !mode.off? && heating_mode?(@mode_choices[@current_mode_id])
          return Status.success
        end
        change_mode(target)
      end
    end

    private def change_water_mode(id : UInt8) : WaterMode::ChangeToModeResponse
      target = @mode_choices[id]?
      return WaterMode::ChangeToModeResponse.new(WaterMode::ModeStatus::UnsupportedMode) unless target
      status = @commands.synchronize { change_mode(target) }
      if status.success?
        WaterMode::ChangeToModeResponse.new(WaterMode::ModeStatus::Success)
      else
        WaterMode::ChangeToModeResponse.new(WaterMode::ModeStatus::GenericFailure, "EcoNet rejected or could not send the mode")
      end
    end

    private def change_mode(target : Mode, *, stopping : Bool = false) : Status
      return Status.failure if @stop.closed? && !stopping
      @heater.mode = target
      clear_boost if @boost_previous
      remember_mode(target) if heating_mode?(target)
      report_mode(target.vacation? ? VACATION_ID : target.value.to_u8)
      Status.success
    rescue ArgumentError
      Status.constraint_error
    rescue error : EcoNet::Error
      Log.warn { "EcoNet mode command failed (#{error.class})" }
      Status.failure
    end

    private def change_setpoint(target : Int16) : Status
      @commands.synchronize do
        return Status.failure if @stop.closed?
        @heater.set_point_celsius = Thermostat.celsius(target)
        report_setpoint(target)
        Status.success
      end
    rescue ArgumentError
      Status.constraint_error
    rescue error : EcoNet::Error
      Log.warn { "EcoNet temperature command failed (#{error.class})" }
      Status.failure
    end

    private def report_setpoint(target : Int16) : Nil
      @thermostats.each(&.occupied_heating_setpoint=(target))
    end

    private def report_mode(id : UInt8) : Nil
      @current_mode_id = id
      @water_mode.report_current_mode(id)
      heating_enabled = heating_mode?(@mode_choices[id])
      @thermostats.each { |cluster| cluster.report_mode(heating_enabled, heating_enabled && @reported_running) }
    end

    private def report_heat_demand(state : HeaterState) : Nil
      source = Management::HeatSource::None
      if state.running
        supported = @management.heater_types
        running = state.running_state.try(&.downcase) || ""
        source = if supported.heat_pump? && running.includes?("compressor")
                   Management::HeatSource::HeatPump
                 elsif supported.immersion_element1? && running.includes?("element")
                   Management::HeatSource::ImmersionElement1
                 else
                   supported
                 end
      end
      @management.report_heat_demand(source)
    end

    private def mode_id(mode : Mode) : UInt8?
      return if mode.unknown?
      return VACATION_ID if mode.off? || mode.vacation?
      id = mode.value.to_u8
      id if @mode_choices.has_key?(id)
    end

    private def heating_mode?(mode : Mode) : Bool
      !mode.in?(Mode::Unknown, Mode::Vacation, Mode::Off, Mode::PeakNoHeating, Mode::ShoulderNoHeating, Mode::NoHeatingOff)
    end

    private def mode_options : Array(WaterMode::ModeOption)
      @mode_choices.map do |id, mode|
        if mode.vacation?
          tags = [WaterMode::ModeTag.new(WaterMode::Tag::Off), WaterMode::ModeTag.new(WaterMode::Tag::Vacation)]
          WaterMode::ModeOption.new("Vacation", id, tags)
        else
          tags = [
            WaterMode::ModeTag.new(heating_mode?(mode) ? WaterMode::Tag::Manual : WaterMode::Tag::Off),
            WaterMode::ModeTag.new(VENDOR_TAG_BASE + id, vendor_id),
          ]
          if mode.in?(Mode::HighDemand, Mode::Performance)
            tags << WaterMode::ModeTag.new(WaterMode::Tag::Quick)
          elsif mode.in?(Mode::EnergySaving, Mode::OffPeak, Mode::Solar)
            tags << WaterMode::ModeTag.new(WaterMode::Tag::LowEnergy)
          end
          label = mode.to_s.underscore.split('_').join(' ', &.capitalize)
          WaterMode::ModeOption.new(label, id, tags)
        end
      end
    end

    private def accuracy(type : Power::MeasurementType, maximum : Int64) : Power::Accuracy
      # The cloud and optional meter do not declare a metrological calibration.
      range = Energy::Measurement::AccuracyRange.new(0_i64, maximum, percent_max: Energy::Measurement::PERCENT_LIMIT)
      Power::Accuracy.new(type, false, 0_i64, maximum, [range])
    end

    private def read_mode(record : String, key : String) : Mode?
      value = @storage.read(STORAGE_COLLECTION, record).try(&.[key]?).as?(Int64)
      Mode.from_value?(value) if value
    end

    private def remember_mode(mode : Mode) : Nil
      current = read_mode(HEAT_MODE_RECORD, "mode")
      if current != mode
        @storage.write(STORAGE_COLLECTION, HEAT_MODE_RECORD, Matter::Storage::Document{"mode" => mode.value.to_i64})
      end
      @heat_mode = mode
    end

    private def load_identity : Tuple(UInt16, UInt32, String)
      if record = @storage.read(STORAGE_COLLECTION, IDENTITY_RECORD)
        if record["heater"]? != @heater.serial_number
          raise ArgumentError.new("This Matter storage file belongs to a different EcoNet heater")
        end
        return {record["discriminator"].as(Int64).to_u16, record["pin"].as(Int64).to_u32, record["unique_id"].as(String)}
      end
      discriminator = Matter::SetupPayload.generate_random_discriminator
      pin = Matter::SetupPayload.generate_random_pin
      unique_id = Matter::SetupPayload.generate_unique_id
      @storage.write(STORAGE_COLLECTION, IDENTITY_RECORD, Matter::Storage::Document{
        "heater" => @heater.serial_number, "discriminator" => discriminator.to_i64, "pin" => pin.to_i64, "unique_id" => unique_id,
      })
      {discriminator, pin, unique_id}
    end

    private def start_boost(info : Management::BoostInfo) : Status
      target = @mode_choices.values.find(&.in?(Mode::HighDemand, Mode::Performance))
      return Status.unsupported_command unless target
      if {info.one_shot, info.emergency_boost, info.temporary_setpoint, info.target_percentage, info.target_reheat}.any? { |option| option }
        return Status.constraint_error
      end
      @commands.synchronize do
        return Status.failure if @stop.closed?
        previous = @boost_previous || @mode_choices[@current_mode_id]
        @storage.write(STORAGE_COLLECTION, BOOST_RECORD, Matter::Storage::Document{
          "previous" => previous.value.to_i64, "target" => target.value.to_i64,
        })
        begin
          @heater.mode = target
        rescue error
          @storage.delete(STORAGE_COLLECTION, BOOST_RECORD) unless @boost_previous
          raise error
        end
        @boost_previous = previous
        @boost_target = target
        report_mode(target.value.to_u8)
        Status.success
      end
    rescue ArgumentError
      Status.constraint_error
    rescue error : EcoNet::Error
      Log.warn { "EcoNet boost command failed (#{error.class})" }
      Status.failure
    end

    private def cancel_boost(*, stopping : Bool = false) : Status
      @commands.synchronize do
        previous = @boost_previous
        return Status.success unless previous
        change_mode(previous, stopping: stopping)
      end
    end

    private def clear_boost : Nil
      @storage.delete(STORAGE_COLLECTION, BOOST_RECORD)
      @boost_previous = @boost_target = nil
      @boost_confirmed = false
      @management.finish_boost
    end

    private def recover_boost : Nil
      return unless @boost_previous && @management.boost_state.inactive?
      if @heater.state.mode == @boost_target
        cancel_boost
      else
        @commands.synchronize { clear_boost }
      end
    end

    private def refresh : Nil
      @heater.refresh
      reconcile
    rescue error : EcoNet::Error
      Log.warn { "EcoNet state refresh failed (#{error.class})" }
    end

    private def subscribe : Nil
      @heater.subscribe { reconcile }
      recover_boost
    rescue error : EcoNet::Error
      Log.warn { "EcoNet subscription failed (#{error.class})" }
    end

    private def poll_energy(now : Time) : Nil
      today = now.at_beginning_of_day
      if @energy.last_end.try { |ending| ending < today } != false
        yesterday = today.shift(days: -1)
        if readings = @heater.electrical_usage(yesterday)
          @energy.record(readings, yesterday, now)
        end
        # Keep the last hour of yesterday eligible until the cloud closes it.
        return if now < today + Energy::REPORT_DELAY
      end
      if readings = @heater.electrical_usage(today)
        @energy.record(readings, today, now)
      end
    rescue error : EcoNet::Error
      Log.warn { "EcoNet energy poll failed (#{error.class})" }
    end

    private def poll_power : Nil
      value = @power_watts.try(&.call)
      @power.active_power = if value && value.finite? && 0 <= value <= MAX_POWER_MW / MW_PER_WATT
                              (value * MW_PER_WATT).round.to_i64
                            end
    rescue error
      @power.active_power = nil
      Log.warn { "Power meter read failed (#{error.class})" }
    end

    private def poll : Nil
      next_refresh = next_energy = Time.instant
      until @stop.closed?
        now = Time.instant
        if now >= next_refresh
          refresh
          subscribe unless @stop.closed?
          next_refresh = Time.instant + REFRESH_PERIOD
        end
        break if @stop.closed?
        if now >= next_energy
          poll_energy(Time.local)
          next_energy = Time.instant + ENERGY_PERIOD
        end
        poll_power
        select
        when @stop.receive?
          break
        when timeout(POLL_TICK)
        end
      end
    rescue error
      Log.error { "EcoNet polling stopped (#{error.class})" }
    end
  end
end
