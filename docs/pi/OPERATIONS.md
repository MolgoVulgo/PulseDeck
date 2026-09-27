# Exploitation Raspberry Pi

## Contrôle global

Sans modification :

```bash
./scripts/setup_pi.sh --check
./scripts/setup_pi.sh --check --verbose
```

Application/réparation de la configuration gérée PulseDeck :

```bash
sudo ./scripts/setup_pi.sh
```

Le script ne lance aucune mise à jour globale Arch Linux.

## Mosquitto

État :

```bash
systemctl status mosquitto --no-pager
```

Logs :

```bash
journalctl -u mosquitto
journalctl -u mosquitto -f
```

Listeners :

```bash
ss -lntp | grep ':1883'
```

Le listener attendu est uniquement l'IPv4 LAN du Pi sur le port `1883`.

## Validation de configuration

Avec Mosquitto 2.1 ou supérieur :

```bash
mosquitto --test-config -c /etc/mosquitto/mosquitto.conf
```

## Test MQTT manuel

Dans un premier terminal :

```bash
mosquitto_sub -h <IP_PI> -p 1883 -t 'pulsedeck/v1/test' -v
```

Dans un second :

```bash
mosquitto_pub -h <IP_PI> -p 1883 -t 'pulsedeck/v1/test' -m 'hello'
```

Pour tester retained :

```bash
mosquitto_pub -h <IP_PI> -p 1883 -q 1 -r -t 'pulsedeck/v1/test' -m 'retained'
mosquitto_sub -h <IP_PI> -p 1883 -t 'pulsedeck/v1/test' -C 1
```

Nettoyage du retained de test :

```bash
mosquitto_pub -h <IP_PI> -p 1883 -q 1 -r -n -t 'pulsedeck/v1/test'
```

## Limites de validation

Un test exécuté depuis le Pi vers sa propre IPv4 LAN valide le bind et le chemin local, mais ne prouve pas à lui seul l'accessibilité depuis un autre équipement du LAN ni une éventuelle politique de filtrage externe. Le test depuis l'ESP32 constituera la validation LAN complète.

Le Last Will `pulsedeck/v1/system/availability` sera validé avec le service hub, pas avec le broker seul.
