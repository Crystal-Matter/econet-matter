module EcoNetMatter
  # Both endpoint views feed the same callbacks. Local reports use the normal
  # Matter setters directly, so reporting never loops back into EcoNet.
  @[Matter::Cluster::RegistryExclude]
  class Thermostat < Matter::Cluster::Thermostat
    CENTI_DEGREES_PER_DEGREE = 100.0

    def initialize(endpoint_id : UInt16, bounds : Tuple(Int16, Int16), target : Int16,
                   @write_mode : Proc(SystemMode, Status), @write_setpoint : Proc(Int16, Status),
                   *, @display_target_as_temperature : Bool = false)
      minimum, maximum = bounds
      super(Matter::DataType::EndpointNumber.new(endpoint_id),
        feature_map: Feature::Heating | Feature::Events,
        abs_min_heat_setpoint_limit: minimum, abs_max_heat_setpoint_limit: maximum,
        min_heat_setpoint_limit: minimum, max_heat_setpoint_limit: maximum,
        occupied_heating_setpoint: target, control_sequence_of_operation: ControlSequenceOfOperation::HeatingOnly,
        local_temperature: @display_target_as_temperature ? target : nil)
    end

    protected def handle_write_attribute(attribute_id : UInt32, value : TLV::Any) : Status
      case attribute_id
      when ATTR_SYSTEM_MODE
        return Status.invalid_data_type unless mode = narrow_u8?(value)
        setting = SystemMode.from_value?(mode)
        return Status.constraint_error unless setting && setting.in?(SystemMode::Off, SystemMode::Heat)
        @write_mode.call(setting)
      when ATTR_OCCUPIED_HEATING_SETPOINT
        return Status.invalid_data_type unless target = signed?(value, Int16)
        write_target(target)
      else
        super
      end
    end

    def setpoint_raise_lower(request : SetpointRaiseLowerRequest) : Status
      return Status.invalid_command if request.mode.cool?
      delta = request.amount.to_i32 * DECI_TO_CENTI_DEGREES
      target = (@occupied_heating_setpoint.to_i32 + delta).clamp(
        @min_heat_setpoint_limit.to_i32, @max_heat_setpoint_limit.to_i32)
      write_target(target.to_i16)
    end

    def report_mode(heating_enabled : Bool, heating_now : Bool) : Nil
      self.system_mode = heating_enabled ? SystemMode::Heat : SystemMode::Off
      self.thermostat_running_mode = heating_now ? ThermostatRunningMode::Heat : ThermostatRunningMode::Off
    end

    def report_setpoint(target : Int16) : Nil
      self.occupied_heating_setpoint = target
      self.local_temperature = target if @display_target_as_temperature
    end

    # The bridge reports the actual running state from EcoNet in #report_mode.
    private def update_running_mode : Nil
    end

    private def write_target(target : Int16) : Status
      return Status.constraint_error unless @min_heat_setpoint_limit <= target <= @max_heat_setpoint_limit
      @write_setpoint.call(target)
    end

    def self.centi_degrees(celsius : Float64) : Int16
      (celsius * CENTI_DEGREES_PER_DEGREE).round.to_i16
    end

    def self.celsius(centi_degrees : Int16) : Float64
      centi_degrees / CENTI_DEGREES_PER_DEGREE
    end
  end
end
