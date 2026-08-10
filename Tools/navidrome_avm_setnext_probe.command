#!/bin/zsh
set -euo pipefail

python3 <<'PY'
import getpass
import hashlib
import html
import json
import secrets
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

try:
    sys.stdin = open("/dev/tty", "r", encoding="utf-8", buffering=1)
except OSError:
    pass

NAVIDROME_BASE = "http://umbrel.local:4533"
AVM_IP = "192.168.0.186"
KNOWN_DESCRIPTION = (
    "http://192.168.0.186:41312/"
    "9e162908-55d4-45b2-93db-7fd295ee46de.xml"
)
CLIENT = "MusiCardsSetNextProbe"
API_VERSION = "1.16.1"
SOAP_NS = "http://schemas.xmlsoap.org/soap/envelope/"


def api_url(endpoint, params):
    return f"{NAVIDROME_BASE}/rest/{endpoint}.view?{urllib.parse.urlencode(params)}"


def fetch_json(endpoint, params):
    with urllib.request.urlopen(api_url(endpoint, params), timeout=15) as response:
        payload = json.load(response).get("subsonic-response", {})
    if payload.get("status") != "ok":
        message = payload.get("error", {}).get("message", "Navidrome API-hiba")
        raise RuntimeError(message)
    return payload


def choose_two_songs(auth):
    result = fetch_json("getRandomSongs", {**auth, "size": 20})
    songs = result.get("randomSongs", {}).get("song", [])
    usable = [song for song in songs if song.get("id")]
    if len(usable) < 2:
        raise RuntimeError("Nem találtam két lejátszható számot.")
    return usable[0], usable[1]


def discover_description():
    try:
        with urllib.request.urlopen(KNOWN_DESCRIPTION, timeout=3) as response:
            if response.status == 200:
                return KNOWN_DESCRIPTION
    except (OSError, urllib.error.URLError):
        pass

    targets = [
        "upnp:rootdevice",
        "urn:schemas-upnp-org:device:MediaRenderer:2",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
    ]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1)
    try:
        for _ in range(3):
            for target in targets:
                message = "\r\n".join([
                    "M-SEARCH * HTTP/1.1",
                    "HOST: 239.255.255.250:1900",
                    'MAN: "ssdp:discover"',
                    "MX: 1",
                    f"ST: {target}",
                    "",
                    "",
                ]).encode()
                # Unicast SSDP az ismert AVM-címre megbízhatóbbnak bizonyult.
                sock.sendto(message, (AVM_IP, 1900))

            while True:
                try:
                    data, address = sock.recvfrom(65535)
                except socket.timeout:
                    break
                if address[0] != AVM_IP:
                    continue
                for line in data.decode("utf-8", "replace").split("\r\n"):
                    if line.lower().startswith("location:"):
                        return line.split(":", 1)[1].strip()
    finally:
        sock.close()
    raise RuntimeError("Az AVM nem válaszolt az SSDP-felderítésre.")


def find_avtransport(description_url):
    with urllib.request.urlopen(description_url, timeout=5) as response:
        root = ET.fromstring(response.read())

    friendly_name = "AVM renderer"
    candidates = []
    for node in root.iter():
        local = node.tag.rsplit("}", 1)[-1]
        if local == "friendlyName":
            friendly_name = node.text or friendly_name
        elif local == "service":
            values = {
                child.tag.rsplit("}", 1)[-1]: child.text or ""
                for child in node
            }
            service_type = values.get("serviceType", "")
            if "schemas-upnp-org:service:AVTransport:" in service_type:
                try:
                    version = int(service_type.rsplit(":", 1)[-1])
                except ValueError:
                    version = 0
                candidates.append((
                    version,
                    service_type,
                    urllib.parse.urljoin(description_url, values["controlURL"]),
                ))

    if not candidates:
        raise RuntimeError("Az AVTransport szolgáltatás hiányzik.")
    version, service_type, control_url = max(candidates, key=lambda item: item[0])
    return friendly_name, version, service_type, control_url


def soap_call(url, service, action, arguments=()):
    envelope = ET.Element(ET.QName(SOAP_NS, "Envelope"), {
        ET.QName(SOAP_NS, "encodingStyle"):
            "http://schemas.xmlsoap.org/soap/encoding/"
    })
    body = ET.SubElement(envelope, ET.QName(SOAP_NS, "Body"))
    action_node = ET.SubElement(body, ET.QName(service, action))
    for name, value in arguments:
        ET.SubElement(action_node, name).text = str(value)

    request = urllib.request.Request(
        url,
        data=ET.tostring(envelope, encoding="utf-8", xml_declaration=True),
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPAction": f'"{service}#{action}"',
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return ET.fromstring(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise RuntimeError(
            f"{action} sikertelen (HTTP {error.code}): {detail}"
        ) from error


def soap_value(root, name):
    return next((
        node.text or ""
        for node in root.iter()
        if node.tag.rsplit("}", 1)[-1] == name
    ), "")


def upnp_time(seconds):
    seconds = max(0, int(seconds or 0))
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}"


def stream_url(song, auth):
    return api_url("stream", {
        **auth,
        "id": song["id"],
        "format": "raw",
        "maxBitRate": 0,
    })


def didl_metadata(song, uri):
    title = html.escape(song.get("title") or "Navidrome track")
    artist = html.escape(song.get("artist") or "")
    album = html.escape(song.get("album") or "")
    mime = html.escape(song.get("contentType") or "audio/flac")
    resource = html.escape(uri, quote=True)
    duration = upnp_time(song.get("duration"))
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<DIDL-Lite '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        f'<item id="{html.escape(str(song["id"]), quote=True)}" '
        'parentID="0" restricted="1">'
        f'<dc:title>{title}</dc:title>'
        f'<upnp:artist>{artist}</upnp:artist>'
        f'<upnp:album>{album}</upnp:album>'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
        f'<res protocolInfo="http-get:*:{mime}:*" duration="{duration}">'
        f'{resource}</res>'
        '</item></DIDL-Lite>'
    )


def print_song(label, song):
    print(f"    {label}:")
    print(f"      {song.get('artist', '—')} — {song.get('title', '—')}")
    print(f"      {song.get('album', '—')}")
    print(
        f"      {song.get('suffix', '—')} / "
        f"{song.get('contentType', '—')}"
    )


def main():
    print("Navidrome → AVM szabványos SetNextAVTransportURI próba")
    print(f"Navidrome: {NAVIDROME_BASE}")
    print(f"AVM:       {AVM_IP}\n")

    username = input("Navidrome-felhasználónév: ").strip()
    password = getpass.getpass("Navidrome-jelszó (nem jelenik meg): ")
    if not username or not password:
        raise RuntimeError("Felhasználónév és jelszó szükséges.")

    salt = secrets.token_hex(8)
    token = hashlib.md5((password + salt).encode("utf-8")).hexdigest()
    password = None
    auth = {
        "u": username,
        "t": token,
        "s": salt,
        "v": API_VERSION,
        "c": CLIENT,
        "f": "json",
    }

    print("\n1/4 Navidrome-hitelesítés és két véletlen szám kiválasztása…")
    first, second = choose_two_songs(auth)
    print_song("Első szám", first)
    print_song("Következő szám", second)

    first_url = stream_url(first, auth)
    second_url = stream_url(second, auth)

    print("\n2/4 A raw stream ellenőrzése…")
    request = urllib.request.Request(first_url, headers={"Range": "bytes=0-0"})
    with urllib.request.urlopen(request, timeout=15) as response:
        status = response.status
        content_type = response.headers.get("Content-Type", "—")
        content_range = response.headers.get("Content-Range", "—")
        response.read(1)
    print(f"    HTTP {status}, Content-Type: {content_type}")
    print(f"    Range támogatás: {content_range}")

    print("\n3/4 Az AVM UPnP-végpontjának felderítése…")
    description = discover_description()
    friendly_name, version, av_service, av_url = find_avtransport(description)
    print(f"    Renderer: {friendly_name}")
    print(f"    AVTransport: {version}")
    print(f"    Vezérlési végpont: {av_url}")

    answer = input(
        "\nElindítsam az első számot, és előkészítsem a másodikat? [y/N] "
    ).strip().lower()
    if answer not in {"y", "yes", "i", "igen"}:
        print("Megszakítva; az AVM állapota nem változott.")
        return

    print("\n4/4 Első és következő stream URL átadása…")
    soap_call(av_url, av_service, "SetAVTransportURI", [
        ("InstanceID", 0),
        ("CurrentURI", first_url),
        ("CurrentURIMetaData", didl_metadata(first, first_url)),
    ])
    soap_call(av_url, av_service, "SetNextAVTransportURI", [
        ("InstanceID", 0),
        ("NextURI", second_url),
        ("NextURIMetaData", didl_metadata(second, second_url)),
    ])

    media_info = soap_call(av_url, av_service, "GetMediaInfo", [
        ("InstanceID", 0),
    ])
    stored_next = soap_value(media_info, "NextURI")
    if stored_next != second_url:
        raise RuntimeError(
            "A SetNextAVTransportURI választ kapott, de a NextURI nem olvasható vissza."
        )
    print("    SetNextAVTransportURI elfogadva és visszaolvasható.")

    soap_call(av_url, av_service, "Play", [
        ("InstanceID", 0),
        ("Speed", "1"),
    ])
    print("    Az első szám lejátszása elindult.")

    duration = int(first.get("duration") or 0)
    if duration <= 12:
        print("    Az első szám túl rövid az automatikus átváltási gyorsteszthez.")
        return

    target_seconds = duration - 12
    target = upnp_time(target_seconds)
    answer = input(
        f"\nUgorjak az első szám utolsó 12 másodpercére ({target})? [Y/n] "
    ).strip().lower()
    if answer in {"n", "no", "nem"}:
        print("A lejátszás folytatódik; az automatikus átváltást nem figyelem.")
        return

    soap_call(av_url, av_service, "Seek", [
        ("InstanceID", 0),
        ("Unit", "REL_TIME"),
        ("Target", target),
    ])
    print("    Seek elfogadva. Legfeljebb 30 másodpercig figyelem az átváltást…")

    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        time.sleep(1)
        position = soap_call(av_url, av_service, "GetPositionInfo", [
            ("InstanceID", 0),
        ])
        current_uri = soap_value(position, "TrackURI")
        rel_time = soap_value(position, "RelTime") or "—"
        if current_uri == second_url:
            print(
                "    SIKER: az AVM önállóan átváltott a második "
                f"Navidrome-számra ({rel_time})."
            )
            print(
                "    A SetNextAVTransportURI-alapú folyamatos lejátszás bizonyított."
            )
            return
        print(f"    Első szám pozíciója: {rel_time}")

    raise RuntimeError("30 másodpercen belül nem észleltem az átváltást.")


try:
    main()
except KeyboardInterrupt:
    print("\nA próba megszakítva; az AVM lejátszása folytatódhat.")
    sys.exit(130)
except Exception as error:
    print(f"\nHIBA: {error}", file=sys.stderr)
    sys.exit(1)
PY
