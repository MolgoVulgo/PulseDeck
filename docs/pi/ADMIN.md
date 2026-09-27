# PulseDeck Admin V1

> English is authoritative. French translation: [`fr/ADMIN.md`](fr/ADMIN.md).

PulseDeck Admin is the lightweight Web UI embedded in the same `pulsedeck-hub` process. No separate Web service is added.

## Access

The deployer binds Admin to the detected LAN IPv4 address on port `8080`:

```text
http://<Pi-LAN-IPv4>:8080
```

The local user is `admin`. The first Web-enabled deployment generates a random initial password and prints it once. Password hash and session key are stored under `/var/lib/pulsedeck/admin` and are never versioned.

## Security model

- bound to the LAN IPv4 address, not `0.0.0.0`;
- authentication required for detailed data and administration actions;
- salted PBKDF2-SHA256 password hash;
- signed HMAC session with `HttpOnly` / `SameSite=Strict` cookie;
- mutation guard and same-origin verification;
- CSP, anti-frame, no-sniff and no-store headers;
- service API keys are never returned in clear text after storage;
- no privileged system command is exposed through the UI.

Admin V1 uses HTTP on the trusted home LAN. Do not expose it directly to the Internet.

## Views

- Dashboard — hub, MQTT, system and collector status;
- Weather — OpenWeather configuration, provider test and hot reload;
- News — GNews mode/filter configuration, provider test and hot reload;
- Services — common collector catalog for implemented and planned services;
- Security — local admin password change.

## Transactional collector changes

For Weather and News, Admin validates the submitted configuration and tests the remote provider before enabling a new working configuration. Runtime TOML and secrets are written atomically. If applying a change fails, PulseDeck attempts to restore the previous working configuration.

## Runtime paths

```text
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/openweather_api_key
/etc/pulsedeck/secrets/gnews_api_key
/var/lib/pulsedeck/admin/password.hash
/var/lib/pulsedeck/admin/session.key
```

`pulsedeck-hub.service` keeps `ProtectSystem=strict` while explicitly allowing writes to `/etc/pulsedeck` and `/var/lib/pulsedeck`.
