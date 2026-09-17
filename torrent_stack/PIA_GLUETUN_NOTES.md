# PIA / Gluetun completion notes

This project has been updated so qBittorrent shares Gluetun's network namespace and has no independent Docker network path.

Before running `./run.sh`, edit `.env` and replace only these two placeholders with the OpenVPN credentials associated with your Private Internet Access subscription:

```env
PIA_OPENVPN_USER=CHANGE_THIS_PIA_OPENVPN_USER
PIA_OPENVPN_PASSWORD=CHANGE_THIS_PIA_OPENVPN_PASSWORD
```

Everything else in `.env` is pre-populated, including generated local passwords for Sonarr, Radarr, Prowlarr and qBittorrent.

Optional settings:

- `PIA_SERVER_REGIONS=`: leave blank for automatic compatible server selection, or set a comma-separated PIA region filter.
- `PIA_PORT_FORWARD_ONLY=true`: restricts selection to PIA servers supporting port forwarding.
- `PIA_VPN_PORT_FORWARDING=on`: enables PIA/Gluetun VPN-side port forwarding and automatic qBittorrent listening-port updates.

The qBittorrent WebUI remains available on host port 8080, but that port is published by Gluetun. Torrent peer traffic is routed through the VPN tunnel, with Gluetun's firewall providing the kill switch.
