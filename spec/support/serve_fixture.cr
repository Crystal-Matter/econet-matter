require "./fake_heater"

storage_path = ARGV[0]? || abort("Pass a path for the temporary Matter state file")
Log.setup(:warn)
power = -> : Float64? { 450.5 }
device = EcoNetMatter::Device.new(FakeHeater.new, Matter::Storage::YamlFile.new(storage_path), port: 0, power_watts: power)
Process.on_terminate { device.shutdown! }
device.start
abort("Matter fixture failed to start") unless device.running?
puts "Matter fixture port: #{device.port}"
STDOUT.flush
device.await_shutdown
