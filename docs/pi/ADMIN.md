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
- the Web process remains unprivileged; update installation is delegated to a separate root `pulsedeck-updater.service` triggered by `pulsedeck-updater.path`;
- the browser cannot submit a shell command, Git ref or arbitrary channel: Web Admin can only queue the already active `stable` or `dev` channel after the update checker reports it as available.

Admin V1 uses HTTP on the trusted home LAN. Do not expose it directly to the Internet.

## Views

- Dashboard — hub, MQTT, system and collector status;
- Weather — OpenWeather configuration, provider test and hot reload;
- News — selectable NewsAPI/GNews provider, provider-specific endpoint/filter configuration, provider test and hot reload;
- Services — common collector catalog for implemented and planned services;
- Logs — in-memory runtime logs with a service filter; `All` is selected by default, with Hub / MQTT / Weather / News / Admin filters;
- Updates — stable/dev checker state and installation of a verified update for the currently active channel;
  The install action opens a confirmation/progress modal that keeps the target visible and follows queued, root-service execution, hub restart/reconnection and final verification. A temporary loss of the Web UI during restart is shown as an expected reconnecting state rather than an installation failure; polling resumes automatically until success, failure or the bounded follow-up timeout.
- Security — local admin password change.

## Runtime logs

The Logs view exposes up to 500 recent Python runtime log entries from the current `pulsedeck-hub` process. Entries are held in RAM only and are lost when the hub restarts, so this feature does not add microSD writes. The default filter is `All`; service-specific filters cover Hub, MQTT, Weather, News and Admin. The view refreshes automatically every five seconds and can also be refreshed manually. It does not execute `journalctl` and does not grant the Web process privileged access to the system journal.

## Transactional collector changes

For Weather and News, Admin validates submitted configuration and tests the remote provider before enabling a new working configuration. News separates provider request fields from PulseDeck runtime fields, fixes provider pagination to page 1 for the current snapshot, and keeps collection cadence / HTTP timeout as local runtime settings. NewsAPI and GNews keys are stored independently, so switching provider does not overwrite the other secret. Runtime TOML and secrets are written atomically. If applying a change fails, PulseDeck attempts to restore the previous working configuration.

## Runtime paths

```text
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/openweather_api_key
/etc/pulsedeck/secrets/newsapi_api_key
/etc/pulsedeck/secrets/gnews_api_key
/var/lib/pulsedeck/admin/password.hash
/var/lib/pulsedeck/admin/session.key
```

`pulsedeck-hub.service` keeps `ProtectSystem=strict`. Its update privilege is limited to writing one strict request contract under `/var/lib/pulsedeck-updater/inbox`; it cannot write the updater status directory or execute the root worker directly.

The privileged updater uses:

```text
/var/lib/pulsedeck-updater/inbox/request.json
/var/lib/pulsedeck-updater/status/status.json
/usr/local/libexec/pulsedeck-updater
/etc/systemd/system/pulsedeck-updater.service
/etc/systemd/system/pulsedeck-updater.path
```

The root worker accepts only fresh `install` requests for `stable` or `dev`, validates file ownership/permissions and the root-owned master launcher, then executes the fixed `pulsedeck --channel <stable|dev> --hub-only --non-interactive` path. Rollback and versioned release caching are intentionally deferred.
