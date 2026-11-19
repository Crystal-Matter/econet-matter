require "../../src/econet_matter"

class FakeHeater < EcoNetMatter::Heater
  alias Mode = EcoNetMatter::Mode
  alias HeatSource = Matter::Cluster::WaterHeaterManagement::HeatSource

  getter serial_number : String = "fixture-heater"
  getter modes : Array(Mode) = [Mode::Off, Mode::Default, Mode::Solar, Mode::Vacation, Mode::HighDemand, Mode::PeakNoHeating]
  getter mode_writes = [] of Mode
  getter temperature_writes = [] of Float64
  property? reject_commands = false
  property state : EcoNetMatter::HeaterState = EcoNetMatter::HeaterState.new(Mode::Solar, 58.0, false, "Not Running", 66)

  def limits_celsius : Tuple(Float64, Float64)?
    {50.0, 70.0}
  end

  def heater_types : HeatSource
    HeatSource::HeatPump | HeatSource::ImmersionElement1
  end

  def subscribe(&updated : -> Nil) : Nil
    updated.call
  end

  def close : Nil
  end

  def refresh : Nil
  end

  def mode=(mode : Mode) : Nil
    raise EcoNet::ConnectionError.new("Fixture is offline") if @reject_commands
    @mode_writes << mode
    @state = @state.copy_with(mode: mode)
  end

  def set_point_celsius=(value : Float64) : Nil
    raise EcoNet::ConnectionError.new("Fixture is offline") if @reject_commands
    @temperature_writes << value
    @state = @state.copy_with(set_point_celsius: value)
  end

  def electrical_usage(day : Time) : Hash(Int32, Float64)?
    (0...24).to_h { |hour| {hour, 0.1} }
  end
end
