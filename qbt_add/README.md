## qbt_add: Add torrents to qBittorrent with category and upload limit by tracker

### Install

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

### Configure rules

Edit `rules.yaml`:

```yaml
defaults:
  category: ""        # optional
  up_limit_kib: 0      # 0 = unlimited

rules:
  - match: "tracker.private.example"
    category: "Private"
    up_limit_kib: 500

  - match_regex: ".*public.*"
    category: "Public"
    up_limit_kib: 0
```

- match: exact tracker hostname
- match_regex: Python regex for hostname
- up_limit_kib: KiB/s. 0 means unlimited.

### Usage

Set environment variables or pass flags:

```bash
export QBT_HOST="http://localhost:8080"
export QBT_USERNAME="admin"
export QBT_PASSWORD="adminadmin"
```

Add a magnet:

```bash
python qbt_add.py "magnet:?xt=urn:btih:...&tr=https://tracker.private.example/announce"
```

Add a .torrent file:

```bash
python qbt_add.py /path/to/file.torrent
```

Flags:

- --host, --username, --password: WebUI credentials (or use env vars)
- --config: path to rules.yaml
- --insecure: skip TLS verification
- --no-unpause: leave the torrent paused after applying rules
- --timeout: wait time for torrent to appear (seconds)

### How it works

- Adds the torrent paused with a unique tag
- Waits for qBittorrent to register it, then reads trackers to get hostnames
- Matches the first rule, creates category if missing, sets category and upload limit
- Removes the temporary tag and resumes (unless --no-unpause)
