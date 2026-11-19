require "spec"
require "./support/fake_heater"

private alias Bridge = EcoNetMatter::Device
private alias Mode = EcoNetMatter::Mode
private alias Thermostat = EcoNetMatter::Thermostat
private alias SystemMode = Matter::Cluster::Thermostat::SystemMode

describe EcoNetMatter::Device do
  it "advertises the standard device types, required clusters and power topology" do
    device = Bridge.new(FakeHeater.new, Matter::Storage::Memory.new, port: 0)
    node = device.node
    node.validate.should be_empty
    heater = node.endpoint!(Bridge::WATER_HEATER_ENDPOINT)
    thermostat = node.endpoint!(Bridge::THERMOSTAT_ENDPOINT)
    electrical = node.endpoint!(Bridge::ELECTRICAL_ENDPOINT)
    heater.device_types.map(&.device_type_id.id).should eq([Bridge::WATER_HEATER_TYPE])
    thermostat.device_types.map(&.device_type_id.id).should eq([Matter::DeviceType::THERMOSTAT])
    electrical.device_types.map(&.device_type_id.id).should eq([Bridge::ELECTRICAL_TYPE])
    heater.has_cluster?(Bridge::Management::CLUSTER_ID).should be_true
    heater.has_cluster?(Bridge::WaterMode::CLUSTER_ID).should be_true
    heater.has_cluster?(Thermostat::CLUSTER_ID).should be_true
    thermostat.has_cluster?(Thermostat::CLUSTER_ID).should be_true
    electrical.has_cluster?(Bridge::Power::CLUSTER_ID).should be_true
    electrical.has_cluster?(EcoNetMatter::Energy::Cluster::CLUSTER_ID).should be_true
    electrical.get_cluster!(Bridge::Topology).available_endpoints.should eq([Bridge::WATER_HEATER_ENDPOINT, Bridge::THERMOSTAT_ENDPOINT])
    device.power.active_power.should be_nil
  ensure
    device.try &.shutdown!
  end

  it "writes through both thermostat views and maps Off to Vacation and Heat to the prior mode" do
    heater = FakeHeater.new
    device = Bridge.new(heater, Matter::Storage::Memory.new, port: 0)
    home = device.home_thermostat
    native = device.heater_thermostat
    target_attribute = Thermostat::ATTR_OCCUPIED_HEATING_SETPOINT
    mode_attribute = Thermostat::ATTR_SYSTEM_MODE

    home.local_temperature.should be_nil
    home.system_mode.should eq(SystemMode::Heat)
    home.thermostat_running_state.should eq(Thermostat::RelayState::None)
    home.occupied_heating_setpoint.should eq(5800)
    home.max_heat_setpoint_limit.should eq(7000)

    home.write_attribute(mode_attribute, TLV::Any.new(SystemMode::Off.value)).success?.should be_true
    heater.mode_writes.should eq([Mode::Vacation])
    native.system_mode.should eq(SystemMode::Off)
    device.water_mode.current_mode.should eq(Bridge::VACATION_ID)

    home.write_attribute(mode_attribute, TLV::Any.new(SystemMode::Cool.value)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    heater.mode_writes.should eq([Mode::Vacation])

    native.write_attribute(mode_attribute, TLV::Any.new(SystemMode::Heat.value)).success?.should be_true
    heater.mode_writes.should eq([Mode::Vacation, Mode::Solar])
    home.system_mode.should eq(SystemMode::Heat)

    home.write_attribute(target_attribute, TLV::Any.new(5900_i16)).success?.should be_true
    native.occupied_heating_setpoint.should eq(5900)
    heater.temperature_writes.should eq([59.0])
    native.setpoint_raise_lower(Thermostat::SetpointRaiseLowerRequest.new(Thermostat::SetpointAdjustMode::Heat, -10_i8)).success?.should be_true
    home.occupied_heating_setpoint.should eq(5800)
    heater.temperature_writes.should eq([59.0, 58.0])

    home.write_attribute(target_attribute, TLV::Any.new(8000_i16)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    heater.reject_commands = true
    native.write_attribute(target_attribute, TLV::Any.new(6100_i16)).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    home.occupied_heating_setpoint.should eq(5800)
    heater.temperature_writes.should eq([59.0, 58.0])
  ensure
    device.try &.shutdown!
  end

  it "synchronizes cloud reports and maps Water Heater Mode changes to EcoNet" do
    heater = FakeHeater.new
    device = Bridge.new(heater, Matter::Storage::Memory.new, port: 0)
    mode = device.water_mode

    change = mode.change_to_mode(Bridge::WaterMode::ChangeToModeRequest.new(Mode::Default.value.to_u8))
    change.status.success?.should be_true
    heater.mode_writes.should eq([Mode::Default])

    heater.state = heater.state.copy_with(mode: Mode::Solar, set_point_celsius: 57.5, running: true, running_state: "Compressor Running", hot_water_percentage: 33)
    device.reconcile
    device.home_thermostat.occupied_heating_setpoint.should eq(5750)
    device.heater_thermostat.occupied_heating_setpoint.should eq(5750)
    device.home_thermostat.thermostat_running_state.should eq(Thermostat::RelayState::Heat)
    mode.current_mode.should eq(Mode::Solar.value)
    device.management.heat_demand.should eq(Bridge::Management::HeatSource::HeatPump)
    device.management.tank_percentage.should eq(33)
    heater.mode_writes.should eq([Mode::Default])
    heater.temperature_writes.should be_empty

    heater.state = heater.state.copy_with(mode: Mode::PeakNoHeating, running: false)
    device.reconcile
    mode.current_mode.should eq(Mode::PeakNoHeating.value)
    device.home_thermostat.system_mode.should eq(SystemMode::Off)
    device.home_thermostat.write_attribute(Thermostat::ATTR_SYSTEM_MODE, TLV::Any.new(SystemMode::Off.value)).success?.should be_true
    heater.mode_writes.should eq([Mode::Default, Mode::Vacation])
  ensure
    device.try &.shutdown!
  end

  it "restores the previous operating mode after canceling a supported boost" do
    heater = FakeHeater.new
    device = Bridge.new(heater, Matter::Storage::Memory.new, port: 0)
    management = device.management
    rejected = Bridge::Management::BoostInfo.new(60_u32, temporary_setpoint: 6100_i16)
    management.boost(Bridge::Management::BoostRequest.new(rejected)).success?.should be_false
    heater.mode_writes.should be_empty
    boost = Bridge::Management::BoostInfo.new(60_u32)
    management.boost(Bridge::Management::BoostRequest.new(boost)).success?.should be_true
    management.boost_state.active?.should be_true
    management.cancel_boost.success?.should be_true
    management.boost_state.inactive?.should be_true
    heater.mode_writes.should eq([Mode::HighDemand, Mode::Solar])
  ensure
    device.try &.shutdown!
  end

  it "converts completed hourly kWh to mWh and keeps the metering cursor across restarts" do
    storage = Matter::Storage::Memory.new
    heater = FakeHeater.new
    device = Bridge.new(heater, storage, port: 0)
    day = Time.utc(2026, 1, 2)
    report = {0 => 0.4, 1 => 0.65, 2 => 0.2}

    device.energy.record(report, day, day + 2.hours + 1.minute)
    device.electrical_energy.cumulative_energy_imported.try(&.energy).should eq(400_000)
    device.energy.record(report, day, day + 2.hours + 10.minutes)
    device.energy.record(report, day, day + 2.hours + 20.minutes)
    device.electrical_energy.cumulative_energy_imported.try(&.energy).should eq(1_050_000)
    device.electrical_energy.periodic_energy_imported.try(&.energy).should eq(650_000)
    device.energy.last_end.should eq(day + 2.hours)
    pin = device.setup_pin
    device.shutdown!

    restarted = Bridge.new(heater, storage, port: 0)
    restarted.setup_pin.should eq(pin)
    restarted.energy.record(report, day, day + 3.hours + 10.minutes)
    restarted.electrical_energy.cumulative_energy_imported.try(&.energy).should eq(1_250_000)
    restarted.electrical_energy.periodic_energy_imported.try(&.energy).should eq(200_000)
  ensure
    device.try &.shutdown!
    restarted.try &.shutdown!
  end
end
