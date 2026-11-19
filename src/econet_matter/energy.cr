module EcoNetMatter
  # Convert completed EcoNet report periods without guessing instantaneous power.
  class Energy
    alias Cluster = Matter::Cluster::ElectricalEnergyMeasurement
    alias Measurement = Matter::Cluster::ElectricalMeasurement

    MWH_PER_KWH   = 1_000_000
    MATTER_EPOCH  = Time.utc(2000, 1, 1)
    REPORT_DELAY  = 5.minutes
    HOURS_PER_DAY = 24

    COLLECTION = "econet_matter"
    RECORD_ID  = "energy"

    record Period, start_at : Time, end_at : Time, energy_mwh : Int64
    record MeterState, start_at : Time, total_mwh : Int64, latest : Period

    @state : MeterState?

    def initialize(@storage : Matter::Storage::Backend, @cluster : Cluster)
      @state = load
      if state = @state
        @cluster.cumulative_energy_imported = cumulative(state)
        @cluster.periodic_energy_imported = periodic(state.latest)
      end
    end

    def last_end : Time?
      @state.try(&.latest.end_at)
    end

    def record(report : Hash(Int32, Float64), day : Time, now : Time) : Nil
      cutoff = now - REPORT_DELAY
      ending = day.shift(days: 1)
      if ending - day != 1.day
        # Date changes can skip or repeat an hour in a clock-labelled report.
        # Only use the aggregate once the whole civil day is complete.
        return unless cutoff >= ending && report.values.all? { |value| valid_energy?(value) }
        add_period(day, ending, report.values.sum)
        return
      end

      start_index = report.has_key?(0) ? 0 : 1
      report.keys.sort!.each do |index|
        next unless start_index <= index < start_index + HOURS_PER_DAY
        hour = index - start_index
        starts_at = day + hour.hours
        ends_at = starts_at + 1.hour
        add_period(starts_at, ends_at, report[index]) if ends_at <= cutoff
      end
    end

    private def add_period(start_at : Time, end_at : Time, energy_kwh : Float64) : Nil
      previous = @state
      return if previous && start_at < previous.latest.end_at
      return unless valid_energy?(energy_kwh)

      amount = (energy_kwh * MWH_PER_KWH).round.to_i64
      total_before = previous.try(&.total_mwh) || 0_i64
      return if amount > Measurement::MEASUREMENT_LIMIT - total_before
      total = total_before + amount

      period = Period.new(start_at, end_at, amount)
      state = MeterState.new(previous.try(&.start_at) || start_at, total, period)
      @storage.write(COLLECTION, RECORD_ID, Matter::Storage::Document{
        "start_at" => state.start_at, "total_mwh" => total,
        "period_start" => start_at, "period_end" => end_at, "period_mwh" => amount,
      })
      @state = state
      @cluster.record_periodic(imported: periodic(period))
      @cluster.record_cumulative(imported: cumulative(state))
    end

    private def valid_energy?(value : Float64) : Bool
      value.finite? && 0 <= value <= Measurement::MEASUREMENT_LIMIT / MWH_PER_KWH
    end

    private def load : MeterState?
      return unless row = @storage.read(COLLECTION, RECORD_ID)
      starts_at = row["start_at"]?.as?(Time)
      total = row["total_mwh"]?.as?(Int64)
      period_start = row["period_start"]?.as?(Time)
      period_end = row["period_end"]?.as?(Time)
      amount = row["period_mwh"]?.as?(Int64)
      if starts_at && total && period_start && period_end && amount
        MeterState.new(starts_at, total, Period.new(period_start, period_end, amount))
      end
    end

    private def cumulative(state : MeterState) : Cluster::EnergyMeasurement
      measurement(state.total_mwh, state.start_at, state.latest.end_at)
    end

    private def periodic(period : Period) : Cluster::EnergyMeasurement
      measurement(period.energy_mwh, period.start_at, period.end_at)
    end

    private def measurement(energy : Int64, starts_at : Time, ends_at : Time) : Cluster::EnergyMeasurement
      Cluster::EnergyMeasurement.new(energy,
        (starts_at.to_unix - MATTER_EPOCH.to_unix).to_u32,
        (ends_at.to_unix - MATTER_EPOCH.to_unix).to_u32)
    end
  end
end
