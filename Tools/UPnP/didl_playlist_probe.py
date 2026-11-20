#!/usr/bin/env python3
"""Temporary DIDL_S playlist handoff experiment; never proxies audio.

Uses Python's standard library. Credentials, stream URLs and playlist XML stay
in memory. Run test_didl_playlist_probe.py offline before a hardware experiment.
"""
import argparse
import getpass
import hashlib
import http.server
import ipaddress
import json
import secrets
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from contextlib import contextmanager

SOAP = "http://schemas.xmlsoap.org/soap/envelope/"
DIDL = "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
DC = "http://purl.org/dc/elements/1.1/"
UPNP = "urn:schemas-upnp-org:metadata-1-0/upnp/"
PROFILE = "DLNA.ORG_PN=DIDL_S"
MAX_RESPONSE = 4 * 1024 * 1024
for prefix, namespace in [("", DIDL), ("dc", DC), ("upnp", UPNP)]:
    ET.register_namespace(prefix, namespace)


class ProbeError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


# LAN traffic should never pass through a configured system HTTP proxy.
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def fault_summary(data):
    # Firmware descriptions can echo the authenticated resource URL. Report
    # only the numeric UPnP code and our own explanation, never raw text.
    meanings = {
        "701": "A művelet ebben az állapotban nem engedélyezett",
        "704": "Nem támogatott formátum", "705": "Zárolt lejátszás",
        "714": "Elutasított MIME-típus", "715": "Tiltott erőforrás-hozzáférés",
        "716": "A lista nem érhető el vagy nem feldolgozható",
        "718": "Érvénytelen lejátszási példány",
    }
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return ""
    code = value(root, "errorCode")
    if not code.isdigit() or len(code) > 4:
        return ""
    return "; UPnP %s (%s)" % (code, meanings.get(code, "Renderer-hiba"))


def request_bytes(url, data=None, headers=None):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with HTTP.open(request, timeout=15) as response:
            result = response.read(MAX_RESPONSE + 1)
    except urllib.error.HTTPError as error:
        # Preserve diagnostic fault codes without exposing response bodies.
        with error:
            summary = fault_summary(error.read(MAX_RESPONSE + 1))
        raise ProbeError("HTTP hiba: %s%s" % (error.code, summary)) from None
    except (OSError, urllib.error.URLError):
        raise ProbeError("Hálózati hiba vagy időtúllépés.") from None
    if len(result) > MAX_RESPONSE:
        raise ProbeError("A válasz túl nagy.")
    return result


def xml_response(data):
    try:
        return ET.fromstring(data)
    except ET.ParseError:
        raise ProbeError("Érvénytelen XML-válasz.") from None


def value(root, name):
    return next((node.text or "" for node in root.iter()
                 if node.tag.rsplit("}", 1)[-1] == name), "")


def local_ipv4(text):
    try:
        address = ipaddress.IPv4Address(text)
    except ipaddress.AddressValueError:
        raise ProbeError("Helyi IPv4-címet adj meg.") from None
    if not (address.is_private or address.is_link_local) or address.is_unspecified or address.is_multicast:
        raise ProbeError("A próba csak helyi hálózati címmel használható.")
    return str(address)


def renderer_url(url, ip, origin=None):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "http" or parsed.hostname != ip or parsed.username or parsed.password or parsed.fragment:
        raise ProbeError("A renderer végpontja nem ugyanazon a helyi eszközön van.")
    if origin and (parsed.scheme, parsed.netloc) != (origin.scheme, origin.netloc):
        raise ProbeError("A renderer szolgáltatásai eltérő végpontra mutatnak.")
    return url


def discover(ip):
    message = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
               'MAN: "ssdp:discover"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n').encode()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(2)
        for _ in range(2):
            sock.sendto(message, (ip, 1900))
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    data, peer = sock.recvfrom(65535)
                except socket.timeout:
                    break
                if peer[0] != ip:
                    continue
                for line in data.decode("utf-8", "replace").split("\r\n"):
                    if line.lower().startswith("location:"):
                        candidate = line.split(":", 1)[1].strip()
                        # Any SSDP service may respond; verify the description
                        # contains AVTransport before accepting its LOCATION.
                        try:
                            root = xml_response(request_bytes(renderer_url(candidate, ip)))
                            if any("service:AVTransport:" in (n.text or "") for n in root.iter()):
                                return candidate
                        except ProbeError:
                            continue
    raise ProbeError("Nincs SSDP-válasz. Add meg az aktuális device description URL-t a --description-url kapcsolóval.")


class Renderer:
    def __init__(self, ip, description):
        self.ip = ip
        root = xml_response(request_bytes(renderer_url(description, ip)))
        origin = urllib.parse.urlsplit(description)
        base = value(root, "URLBase") or description
        renderer_url(base, ip, origin)
        self.name = value(root, "friendlyName") or "UPnP renderer"
        self.services = {}
        for node in root.iter():
            if node.tag.rsplit("}", 1)[-1] != "service":
                continue
            fields = {child.tag.rsplit("}", 1)[-1]: child.text or "" for child in node}
            kind = fields.get("serviceType", "")
            for name in ["AVTransport", "ConnectionManager"]:
                prefix = "urn:schemas-upnp-org:service:%s:" % name
                if kind.startswith(prefix):
                    try:
                        version = int(kind[len(prefix):])
                    except ValueError:
                        continue
                    endpoint = renderer_url(urllib.parse.urljoin(base, fields.get("controlURL", "")), ip, origin)
                    if name not in self.services or version > self.services[name][0]:
                        self.services[name] = (version, kind, endpoint)
        if not all(name in self.services for name in ["AVTransport", "ConnectionManager"]):
            raise ProbeError("A szükséges UPnP-szolgáltatások hiányoznak.")

    def call(self, action, arguments=(), service="AVTransport"):
        _, kind, endpoint = self.services[service]
        root = ET.Element(ET.QName(SOAP, "Envelope"))
        body = ET.SubElement(root, ET.QName(SOAP, "Body"))
        node = ET.SubElement(body, ET.QName(kind, action))
        for name, text in arguments:
            ET.SubElement(node, name).text = str(text)
        try:
            return xml_response(request_bytes(endpoint, ET.tostring(root, encoding="utf-8", xml_declaration=True), {
                "Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": '"%s#%s"' % (kind, action)
            }))
        except ProbeError as error:
            raise ProbeError("%s: %s" % (action, error)) from None

    def status(self):
        transport = self.call("GetTransportInfo", [("InstanceID", 0)])
        position = self.call("GetPositionInfo", [("InstanceID", 0)])
        media = self.call("GetMediaInfo", [("InstanceID", 0)])
        print("Állapot: %s; szám: %s / %s; pozíció: %s / %s" % (
            value(transport, "CurrentTransportState"), value(position, "Track"),
            value(media, "NrTracks"), value(position, "RelTime"), value(position, "TrackDuration")))


class Navidrome:
    def __init__(self, base, username, password):
        parts = urllib.parse.urlsplit(base)
        if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
            raise ProbeError("Érvénytelen Navidrome-cím.")
        try:
            addresses = [item[4][0] for item in socket.getaddrinfo(parts.hostname, parts.port or (443 if parts.scheme == "https" else 80), socket.AF_INET)]
            for address in addresses:
                local_ipv4(address)
        except (OSError, ValueError):
            raise ProbeError("A Navidrome helyi hálózati címét használd.") from None
        self.base = base.rstrip("/")
        salt = secrets.token_hex(8)
        self.auth = {"u": username, "s": salt,
                     "t": hashlib.md5((password + salt).encode()).hexdigest(),
                     "v": "1.16.1", "c": "MusiCardsDIDLProbe", "f": "json"}

    def api(self, action, **params):
        data = request_bytes(self.base + "/rest/" + action + ".view",
                             urllib.parse.urlencode({**self.auth, **params}).encode(),
                             {"Content-Type": "application/x-www-form-urlencoded"})
        try:
            result = json.loads(data)["subsonic-response"]
        except (ValueError, KeyError):
            raise ProbeError("Érvénytelen Navidrome-válasz.") from None
        if result.get("status") != "ok":
            raise ProbeError("A Navidrome elutasította a kérést; ellenőrizd a címet és a belépési adatokat.")
        return result

    def stream(self, song):
        return self.base + "/rest/stream.view?" + urllib.parse.urlencode({
            **self.auth, "id": song["id"], "format": "raw", "maxBitRate": 0})


def time_string(seconds):
    seconds = max(0, int(seconds or 0))
    return "%d:%02d:%02d" % (seconds // 3600, seconds // 60 % 60, seconds % 60)


def add_item(root, song, uri, index, playlist=False):
    node = ET.SubElement(root, ET.QName(DIDL, "item"), {
        "id": str(index), "parentID": "0", "restricted": "1"})
    ET.SubElement(node, ET.QName(DC, "title")).text = song.get("title") or "MusiCards playlist"
    ET.SubElement(node, ET.QName(UPNP, "class")).text = "object.item.playlistItem" if playlist else "object.item.audioItem.musicTrack"
    if not playlist:
        for key in ["artist", "album"]:
            ET.SubElement(node, ET.QName(UPNP, key)).text = song.get(key) or ""
    attributes = {"protocolInfo": "http-get:*:text/xml:" + PROFILE} if playlist else {
        "protocolInfo": "http-get:*:%s:*" % (song.get("contentType") or "audio/flac"),
        "duration": time_string(song.get("duration"))}
    ET.SubElement(node, ET.QName(DIDL, "res"), attributes).text = uri


def playlist_document(songs, urls):
    if len(songs) != len(urls) or len(songs) < 3:
        raise ProbeError("A bizonyító próbához legalább három szám kell.")
    root = ET.Element(ET.QName(DIDL, "DIDL-Lite"))
    for index, (song, uri) in enumerate(zip(songs, urls), 1):
        add_item(root, song, uri, index)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def playlist_metadata(title, url):
    root = ET.Element(ET.QName(DIDL, "DIDL-Lite"))
    add_item(root, {"title": title}, url, "playlist", playlist=True)
    return ET.tostring(root, encoding="unicode")


class FetchStats(list):
    def __init__(self):
        super().__init__()
        self.heads = 0
        self.gets = 0
        self.denied = 0

    def summary(self):
        return "HEAD: %d; GET: %d; elutasított kérés: %d; teljes XML-letöltés: %d" % (
            self.heads, self.gets, self.denied, len(self))


@contextmanager
def serve_once(payload, local_ip, renderer_ip):
    path = "/" + secrets.token_hex(24) + "/album.xml"
    reads = FetchStats()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Paths and response bodies must never be logged.

        def do_HEAD(self):
            self.respond(False)

        def do_GET(self):
            self.respond(True)

        def respond(self, body):
            if body:
                reads.gets += 1
            else:
                reads.heads += 1
            if self.path != path or self.client_address[0] != renderer_ip:
                reads.denied += 1
                self.send_error(404)
                return
            self.send_response(200)
            # Rygel AVTransport compares the literal HEAD header to text/xml.
            # A charset parameter prevents its DIDL_S playlist detection.
            # The XML declaration already specifies UTF-8.
            self.send_header("Content-Type", "text/xml")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("contentFeatures.dlna.org", PROFILE)
            self.send_header("transferMode.dlna.org", "Interactive")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            if body:
                try:
                    self.wfile.write(payload)
                    self.wfile.flush()
                    reads.append(len(payload))
                except (BrokenPipeError, ConnectionResetError):
                    pass

    server = http.server.ThreadingHTTPServer((local_ip, 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://%s:%d%s" % (local_ip, server.server_port, path), reads
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def local_address_for(renderer_ip):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect((renderer_ip, 1900))
        return sock.getsockname()[0]


def handoff(renderer, songs, urls, local_ip):
    """After confirmation, replace current playback. Never call Next/Seek."""
    payload = playlist_document(songs, urls)
    renderer.call("Stop", [("InstanceID", 0)])
    # A previous controller's staged item must not run after the playlist.
    renderer.call("SetNextAVTransportURI", [("InstanceID", 0), ("NextURI", ""), ("NextURIMetaData", "")])
    with serve_once(payload, local_ip, renderer.ip) as (url, reads):
        endpoint = urllib.parse.urlsplit(url)
        print("Ideiglenes listakiszolgáló: %s:%s" % (endpoint.hostname, endpoint.port))
        try:
            renderer.call("SetAVTransportURI", [("InstanceID", 0), ("CurrentURI", url),
                          ("CurrentURIMetaData", playlist_metadata(songs[0].get("album") or "MusiCards test", url))])
        finally:
            print("Listaelérés – " + reads.summary())
        if not reads:
            raise ProbeError("Az AVM nem töltötte le a listát. Nem indítok lejátszást.")
        info = renderer.call("GetMediaInfo", [("InstanceID", 0)])
        if value(info, "NrTracks") != str(len(songs)):
            raise ProbeError("Az AVM nem a teljes számsort igazolta vissza. Nem indítok lejátszást.")
        if value(info, "NextURI"):
            raise ProbeError("Nem üres a következő média; az albumvégi leállás így nem bizonyítható.")
    # The HTTP listener is gone BEFORE Play. No proxy/daemon/controller survives.
    print("A teljes lista átadva (%d szám). A lista kiszolgálása LEÁLLT." % len(songs))
    renderer.call("SetPlayMode", [("InstanceID", 0), ("NewPlayMode", "NORMAL")])
    mode = renderer.call("GetTransportSettings", [("InstanceID", 0)])
    if value(mode, "PlayMode") != "NORMAL":
        raise ProbeError("Nem igazolt a NORMAL mód; nem indítok lejátszást.")
    renderer.call("Play", [("InstanceID", 0), ("Speed", "1")])
    print("Play elküldve. A próba most véget ér; nincs további vezérlés vagy számadagolás.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--renderer-ip")
    parser.add_argument("--description-url")
    parser.add_argument("--status", action="store_true", help="csak állapotlekérdezés, nem változtat semmit")
    args = parser.parse_args()
    print("MusiCards – háromszámos DIDL_S albumsor-próba")
    ip = local_ipv4(args.renderer_ip or input("Renderer helyi IP-címe: ").strip())
    renderer = Renderer(ip, args.description_url or discover(ip))
    print("Renderer: " + renderer.name)
    if args.status:
        renderer.status()
        return
    protocols = renderer.call("GetProtocolInfo", service="ConnectionManager")
    if not any(p.startswith("http-get:") and "text/xml:" in p and PROFILE in p for p in value(protocols, "Sink").split(",")):
        raise ProbeError("A renderer nem hirdet HTTP DIDL_S-támogatást.")
    print("HTTP DIDL_S-támogatás hirdetve.")
    base = input("Navidrome helyi címe (http:// vagy https://): ").strip()
    username = input("Navidrome-felhasználónév: ").strip()
    password = getpass.getpass("Navidrome-jelszó (nem jelenik meg): ")
    client = Navidrome(base, username, password)
    del password
    query = input("Album vagy előadó keresése: ").strip()
    albums = client.api("search3", query=query, artistCount=0, albumCount=10, songCount=0).get("searchResult3", {}).get("album", [])
    if not albums:
        raise ProbeError("Nincs találat.")
    for index, album in enumerate(albums, 1):
        print("%d. %s – %s" % (index, album.get("artist", ""), album.get("name", "")))
    try:
        choice = int(input("Album sorszáma: "))
        if not 1 <= choice <= len(albums):
            raise ValueError()
    except ValueError:
        raise ProbeError("Érvénytelen sorszám.") from None
    songs = client.api("getAlbum", id=albums[choice - 1]["id"]).get("album", {}).get("song", [])
    songs = [song for song in songs if song.get("id")]
    if len(songs) < 3:
        raise ProbeError("Legalább háromszámos albumot válassz.")
    try:
        count = int(input("Hány szám legyen a próbában? [3; 0 = teljes album]: ") or "3")
    except ValueError:
        raise ProbeError("Érvénytelen darabszám.") from None
    if count != 0 and not 3 <= count <= len(songs):
        raise ProbeError("Legalább három számot vagy 0-t adj meg.")
    songs = songs if count == 0 else songs[:count]
    for index, song in enumerate(songs, 1):
        print("%d. %s (%s)" % (index, song.get("title", ""), time_string(song.get("duration"))))
    print("\nZárd be mindkét MusiCards appot, hogy ne adagoljanak új számokat.")
    print("A próba lecseréli az AVM aktuális lejátszását; a zenefájlokat nem módosítja.")
    if input("Indulhat? [i/N]: ").strip().lower() not in ("i", "igen", "y", "yes"):
        print("Megszakítva; a lejátszást nem változtattam meg.")
        return
    handoff(renderer, songs, [client.stream(song) for song in songs], local_address_for(ip))
    print("\nFigyeld meg: 1 → 2 → 3, majd leállás. Ne indíts vezérlő appot közben.")
    print("A --status kapcsolóval később csak az állapotot kérdezheted le.")
    print("A hirdetett támogatás és a sikeres Play még nem bizonyítja a számváltásokat.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nMegszakítva. A renderer lejátszása folytatódhat.")
        raise SystemExit(130)
    except ProbeError as error:
        print("HIBA: " + str(error))
        raise SystemExit(1)
    except Exception as error:
        print("HIBA (%s). Érzékeny részleteket nem naplózok." % type(error).__name__)
        raise SystemExit(1)
