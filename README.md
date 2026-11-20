# EcoNet Matter

Expose one Rheem EcoNet water heater as a Matter node on your local network. The service uses the Crystal EcoNet shard and the Crystal Matter `develop` branch. [EcoNet](https://github.com/stakach/econet.cr) · [Crystal Matter](https://github.com/Crystal-Matter/matter/tree/develop)

| Endpoint | Matter device type | Controls and readings |
| --- | --- | --- |
| 1 | Water Heater `0x050F` | Water Heater Management, Water Heater Mode, and a heating-only Thermostat |
| 2 | Thermostat `0x0301` | Apple Home-facing target temperature, Off and Heat, and heating relay state |
| 3 | Electrical Sensor `0x0510` | Electrical Power Measurement, Electrical Energy Measurement, and Power Topology linking the readings to both heater views |

Both thermostat views operate the same heater. **Off** selects EcoNet Vacation, called **Holiday** on some models. **Heat** restores the previous heating mode. The heater must advertise Vacation or Holiday and at least one heating mode. The service uses the heater's reported set-point limits and sends the temperature through the EcoNet Celsius setter. Changes from EcoNet update both endpoints. The Apple Home thermostat displays the target in its current-temperature field because EcoNet supplies the target without a measured tank temperature.

Water Heater Management includes heat demand and the tank availability reported by the heater. Timed Boost is available on heaters that advertise High Demand or Performance. The service restores the previous mode on cancellation or expiry. The separate Boost control advertised by some Rheem models, including Nash, has no verified EcoNet command mapping in this service.

## Run

Requires Crystal 1.22 or newer and a machine on the same LAN as the Matter controller.

```sh
shards install
shards build econet-matter
export ECONET_EMAIL=you@example.com
read -rsp 'EcoNet password: ' ECONET_PASSWORD
export ECONET_PASSWORD
bin/econet-matter
```

At first start, scan the terminal QR code or enter the manual pairing code in your controller. Use Apple Home for the thermostat view. An iOS companion app can use MatterSupport to onboard the node and the Matter framework to access the native clusters. This project uses the Crystal Matter development attestation identity.

| Environment variable | Purpose |
| --- | --- |
| `ECONET_SERIAL_NUMBER` | Select the heater if your account contains more than one |
| `MATTER_STORAGE_FILE` | Pairing, saved mode and energy state. Defaults to `data/econet-matter.yml` |
| `MATTER_PORT` | Matter port, with 5540 as the default. Set 0 to choose an available port |
| `TZ` | Set this to the heater's time zone when the host uses a different zone, for example `Australia/Sydney` |
| `ECONET_POWER_FILE` | Optional path to a meter's latest numeric active power reading in watts |
| `LOG_LEVEL` | Defaults to `info` |

Keep the state file between runs to retain Matter pairing. Use a separate file for each water heater.

At startup, EcoNet connection failures retry with exponential backoff, from 5 seconds up to 5 minutes. An HTTP 429 starts the wait at one minute or longer. If the serial number does not match a heater, or EcoNet rejects the credentials, startup pauses until you correct the settings and restart the service.

## Docker

Run Compose with host networking on a Linux machine on the same LAN as your Matter controller. The image builds with `84codes/crystal:latest-alpine` and runs as UID 10001. Compose stores pairing and energy state in the `matter-data` volume.

Create a `.env` file beside `docker-compose.yml` with your account details and the heater's time zone.

```dotenv
ECONET_EMAIL=you@example.com
ECONET_PASSWORD='your EcoNet password'
TZ=Australia/Sydney
```

```sh
docker compose build --pull
docker compose up -d
docker compose logs -f econet-matter
```

After correcting a value in `.env`, run `docker compose up -d` to apply the new configuration.

Use the manual pairing code from the log. For an external power meter, mount its containing directory read-only and point `ECONET_POWER_FILE` to the reading inside the container. The reading must be accessible to UID 10001.

### Publish the Docker image

Sign in to Docker Hub with an account that can push to `stakach/econet-matter`, then run the release script.

```sh
docker login
./scripts/publish-image.sh
```

The script pulls the current builder image and uses Docker Buildx to publish one `stakach/econet-matter:latest` tag for `linux/amd64` and `linux/arm64`. The Dockerfile runs the Crystal compiler on the builder's native platform and links the result on each target platform.

## Electrical readings

The service converts completed hourly EcoNet kWh readings to Matter mWh. It exposes the most recent completed period and a cumulative total of imported electricity recorded by the service. The total and the last processed period are persisted to avoid double-counting after a restart. Each poll looks at today's report and, until it finishes it, yesterday's report.

EcoNet supplies energy history for the tested heater. For live power, have a meter update the file named by `ECONET_POWER_FILE` with a single numeric watt reading, for example `450.5`. The ActivePower attribute is null when the file is absent, invalid, or older than two minutes. Home app display of energy readings depends on controller support for the Electrical Sensor endpoint.

## Development

```sh
crystal spec
```

The specs drive Matter writes against a simulated heater and verify the endpoint layout, mode and temperature synchronization, boost, and energy persistence.

To commission a simulated heater with `chip-tool`, start the fixture with a fresh state path and pass the printed QR payload to `chip-tool pairing code`.

```sh
mkdir -p data
crystal run spec/support/serve_fixture.cr -- data/matter-fixture.yml
```
