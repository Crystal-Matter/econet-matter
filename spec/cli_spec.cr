require "spec"
require "../src/econet_matter"
require "../src/econet_matter/cli"

describe EcoNetMatter::CLI do
  it "keeps bridge trace logs and MQTT reconnects while filtering MQTT packet dumps" do
    builder = Log::Builder.new
    backend = Log::MemoryBackend.new
    EcoNetMatter::CLI.configure_logging(:trace, backend, builder: builder)

    builder.for("econet_matter").trace { "bridge trace" }
    builder.for("matter.transport").debug { "Matter debug" }
    builder.for("mqtt").debug { "MQTT packet dump" }
    builder.for("mqtt.tcp").trace { "MQTT packet trace" }
    builder.for("mqtt").info { "reconnected after 1 attempt(s)" }

    backend.entries.map(&.message).should eq(["bridge trace", "Matter debug", "reconnected after 1 attempt(s)"])
  end

  it "honors stricter log levels for both the bridge and MQTT" do
    builder = Log::Builder.new
    backend = Log::MemoryBackend.new
    EcoNetMatter::CLI.configure_logging(:warn, backend, builder: builder)

    builder.for("econet_matter").info { "bridge info" }
    builder.for("mqtt").info { "MQTT info" }
    builder.for("mqtt").warn { "MQTT warning" }

    backend.entries.map(&.message).should eq(["MQTT warning"])
  end
end
