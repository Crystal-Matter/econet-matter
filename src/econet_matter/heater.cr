module EcoNetMatter
  record HeaterState,
    mode : Mode,
    set_point_celsius : Float64?,
    running : Bool,
    running_state : String?,
    hot_water_percentage : Int32?

  # The adapter boundary lets a Matter node be exercised without sending
  # commands to a physical water heater.
  abstract class Heater
    abstract def serial_number : String
    abstract def modes : Array(Mode)
    abstract def limits_celsius : Tuple(Float64, Float64)?
    abstract def heater_types : Matter::Cluster::WaterHeaterManagement::HeatSource
    abstract def state : HeaterState
    abstract def subscribe(&updated : -> Nil) : Nil
    abstract def close : Nil
    abstract def refresh : Nil
    abstract def mode=(mode : Mode) : Nil
    abstract def set_point_celsius=(value : Float64) : Nil
    abstract def electrical_usage(day : Time) : Hash(Int32, Float64)?
  end

  class EcoNetHeater < Heater
    alias HeatSource = Matter::Cluster::WaterHeaterManagement::HeatSource

    # Nash is a heat pump with electric backup. Older EcoNet models use
    # "heatpumpWaterHeater" at the start of their model family identifier.
    NASH_MODEL = "nashWaterHeater"

    def initialize(@client : EcoNet::Client, @heater : EcoNet::WaterHeater)
    end

    def serial_number : String
      @heater.serial_number
    end

    def modes : Array(Mode)
      @heater.modes
    end

    def limits_celsius : Tuple(Float64, Float64)?
      @heater.set_point_limits_celsius
    end

    def heater_types : HeatSource
      model = @heater.generic_type.try(&.downcase) || ""
      if model == NASH_MODEL.downcase || model.starts_with?("heatpumpwaterheater")
        HeatSource::HeatPump | HeatSource::ImmersionElement1
      elsif model.includes?("electric")
        HeatSource::ImmersionElement1
      else
        HeatSource::Other
      end
    end

    def state : HeaterState
      HeaterState.new(@heater.mode, @heater.set_point_celsius,
        @heater.running?, @heater.running_state, @heater.tank_hot_water_availability)
    end

    def subscribe(&updated : -> Nil) : Nil
      @heater.on_update(&updated)
      unless @client.subscribe
        raise EcoNet::ConnectionError.new("EcoNet has no equipment to subscribe to")
      end
    end

    def close : Nil
      @heater.set_update_callback(nil)
      @client.unsubscribe
    end

    def refresh : Nil
      @heater.force_update_from_api
    end

    def mode=(mode : Mode) : Nil
      @heater.mode = mode
    end

    def set_point_celsius=(value : Float64) : Nil
      @heater.set_point_celsius = value
    end

    def electrical_usage(day : Time) : Hash(Int32, Float64)?
      # EcoNet's report groups by civil day in the water heater's time zone.
      readings = @heater.get_energy_usage(day + 999.milliseconds, day.shift(days: 1) - 1.millisecond)
      readings if @heater.energy_type == "KWH"
    end
  end
end
