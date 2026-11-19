require "econet"
require "goban"
require "matter"

require "./econet_matter/heater"
require "./econet_matter/thermostat"
require "./econet_matter/energy"
require "./econet_matter/device"

module EcoNetMatter
  Log = ::Log.for(self)

  alias Mode = EcoNet::WaterHeater::Mode
  alias Status = Matter::InteractionModel::Status
end
