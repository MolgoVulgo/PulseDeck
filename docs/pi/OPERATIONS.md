# Raspberry Pi Operations

> English is authoritative. French translation: [`fr/OPERATIONS.md`](fr/OPERATIONS.md).

## Global checks

```bash
pulsedeck --check
pulsedeck --check --verbose
```

`setup_pi.sh` is an internal worker. Direct execution remains useful for development diagnostics, but the persistent `pulsedeck` command is the normal operational entry point.

## Services

```bash
systemctl status mosquitto --no-pager
systemctl status pulsedeck-hub --no-pager
```

Logs:

```bash
sudo journalctl -u mosquitto -n 100 --no-pager
sudo journalctl -u pulsedeck-hub -n 100 --no-pager -o cat
sudo journalctl -u pulsedeck-hub -f
```

## MQTT checks

Hub availability:

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 \
  -t pulsedeck/v1/system/availability -C 1
```

Weather:

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/availability -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/current -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/hourly -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/daily -C 1
```

News:

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/news/availability -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/news/latest -C 1
```

## Admin health endpoint

The unauthenticated health endpoint is intentionally small:

```bash
curl -fsS http://<PI_IPV4>:8080/api/health
```

Collector configuration and detailed status require an authenticated Admin session.

## Dev Web update smoke test

After deploying the privileged updater handoff, validate the development channel end to end with two consecutive immutable commits:

1. start from dev commit **N** and confirm PulseDeck Admin reports the build as up to date;
2. publish a later dev commit **N+1** without creating a stable GitHub Release;
3. in PulseDeck Admin, run the update check and confirm **N+1** is reported as available;
4. start the installation from PulseDeck Admin;
5. confirm the installer progresses through `queued -> running -> succeeded`, allowing for the hub restart;
6. after the hub returns, confirm the checker reports the dev build as up to date and the installed metadata points to commit **N+1**.

This procedure is a dev-channel smoke test only; it does not define rollback or version-cache behavior.

For the first update after the Web Admin modal is deployed, also confirm that the install button opens the confirmation dialog before queuing the request, shows current and target commits, keeps the progress dialog visible across the expected hub restart/reconnect, and ends in a successful/up-to-date state.

## Runtime configuration

```text
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/openweather_api_key
/etc/pulsedeck/secrets/newsapi_api_key
```

Use PulseDeck Admin for normal collector changes instead of editing these files manually.

## Failure behavior

Last good retained Weather and News snapshots are kept when a remote provider fails. The corresponding `*/availability` topic reports the current source state and a sanitized reason. Provider keys are never logged.
