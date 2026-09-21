import json
import random
import subprocess
import sys
import urllib.parse
import urllib.request

SRV_NAME = "_api._tcp.radio-browser.info"

FIELDS = (
    "name",
    "url_resolved",
    "country",
    "countrycode",
    "tags",
    "codec",
    "bitrate",
    "votes",
    "geo_lat",
    "geo_long",
)


def get_servers():
    result = subprocess.run(
        ["dig", "+short", "SRV", SRV_NAME],
        capture_output=True,
        text=True,
        check=True,
    )

    servers = []

    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 4:
            servers.append(parts[3].rstrip("."))

    if not servers:
        raise RuntimeError("no radio-browser servers found")

    random.shuffle(servers)
    return servers


def fetch_stations():
    params = urllib.parse.urlencode({
        "limit": 10100,
        "order": "votes",
        "reverse": "true",
        "hidebroken": "true",
        "has_geo_info": "true",
    })

    for server in get_servers():
        url = f"https://{server}/json/stations/search?{params}"

        request = urllib.request.Request(
            url,
            headers={"User-Agent": "tmpr-stations/1.0"},
        )

        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                stations = json.load(response)

            if not isinstance(stations, list) or not stations:
                raise RuntimeError("invalid station response")

            print(
                f"using {server}, {len(stations)} stations",
                file=sys.stderr,
            )

            return stations

        except Exception as err:
            print(f"{server}: {err}", file=sys.stderr)

    raise RuntimeError("all radio-browser servers failed")


stations = fetch_stations()

stations = [
    {field: station.get(field) for field in FIELDS}
    for station in stations
]

json.dump(
    stations,
    sys.stdout,
    ensure_ascii=False,
    separators=(",", ":"),
)

sys.stdout.write("\n")