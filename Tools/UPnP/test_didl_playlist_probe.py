import contextlib
import io
import unittest
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

import didl_playlist_probe as probe

SONGS = [{"id": str(i), "title": "Árvíztűrő & track %d" % i,
          "artist": "Artist", "album": "Album", "duration": 123,
          "contentType": "audio/flac"} for i in range(1, 4)]
URLS = ["http://music.local/rest/stream.view?id=%d&t=test-token&s=test-salt" % i for i in range(1, 4)]


def response(**values):
    root = ET.Element("Response")
    for name, text in values.items():
        ET.SubElement(root, name).text = str(text)
    return root


class RendererStub:
    ip = "127.0.0.1"

    def __init__(self, count=3, downloads=True, mode="NORMAL"):
        self.count = count
        self.downloads = downloads
        self.mode = mode
        self.actions = []
        self.payload = None
        self.url = None

    def call(self, action, arguments=(), service="AVTransport"):
        self.actions.append((action, dict(arguments)))
        if action == "SetAVTransportURI":
            self.url = dict(arguments)["CurrentURI"]
            with probe.HTTP.open(urllib.request.Request(self.url, method="HEAD"), timeout=1) as result:
                if result.headers["Content-Type"] != "text/xml":
                    raise AssertionError("Rygel requires the literal text/xml MIME header")
                if result.headers["contentFeatures.dlna.org"] != probe.PROFILE:
                    raise AssertionError("DIDL_S response header missing")
            if self.downloads:
                with probe.HTTP.open(self.url, timeout=1) as result:
                    self.payload = result.read()
        if action == "GetMediaInfo":
            return response(NrTracks=self.count, NextURI="")
        if action == "GetTransportSettings":
            return response(PlayMode=self.mode)
        if action == "Play":
            try:
                with probe.HTTP.open(self.url, timeout=0.5):
                    raise AssertionError("Playlist server is still running during Play")
            except urllib.error.HTTPError:
                raise AssertionError("Playlist server is still listening") from None
            except urllib.error.URLError:
                pass
        return response()


class DIDLPlaylistProbeTests(unittest.TestCase):
    def testSOAPFaultDiagnosticsPreserveCodeButNeverEchoCredentials(self):
        body = b"<Fault><errorCode>714</errorCode><errorDescription>bad http://music.local/?t=SECRET</errorDescription></Fault>"
        summary = probe.fault_summary(body)
        self.assertIn("714", summary)
        self.assertNotIn("SECRET", summary)
        self.assertNotIn("http", summary)
        self.assertEqual(probe.fault_summary(b"not XML SECRET"), "")

    def testXMLPreservesOrderEscapesTokensAndContainsThreeIndependentResources(self):
        root = ET.fromstring(probe.playlist_document(SONGS, URLS))
        items = root.findall("{%s}item" % probe.DIDL)
        self.assertEqual(len(items), 3)
        self.assertEqual([item.find("{%s}res" % probe.DIDL).text for item in items], URLS)
        self.assertEqual([item.find("{%s}title" % probe.DC).text for item in items], [s["title"] for s in SONGS])
        self.assertEqual(items[0].find("{%s}res" % probe.DIDL).get("duration"), "0:02:03")

    def testMetadataDescribesThePlaylistResourceRatherThanAnAudioFile(self):
        root = ET.fromstring(probe.playlist_metadata("Album & title", "http://127.0.0.1/playlist.xml"))
        self.assertEqual(root.find(".//{%s}class" % probe.UPNP).text, "object.item.playlistItem")
        resource = root.find(".//{%s}res" % probe.DIDL)
        self.assertEqual(resource.get("protocolInfo"), "http-get:*:text/xml:DLNA.ORG_PN=DIDL_S")

    def testOneFollowingTrackCannotPassAsAWholePlaylistExperiment(self):
        with self.assertRaises(probe.ProbeError):
            probe.playlist_document(SONGS[:2], URLS[:2])

    def testTemporaryServerHasMatchingHEADAndGETHeadersThenCloses(self):
        data = probe.playlist_document(SONGS, URLS)
        with probe.serve_once(data, "127.0.0.1", "127.0.0.1") as (url, reads):
            with probe.HTTP.open(urllib.request.Request(url, method="HEAD"), timeout=1) as head:
                self.assertEqual(int(head.headers["Content-Length"]), len(data))
                self.assertEqual(head.headers["Content-Type"], "text/xml")
                self.assertEqual(head.read(), b"")
            self.assertEqual(reads, [])
            with probe.HTTP.open(url, timeout=1) as result:
                self.assertEqual(result.headers["contentFeatures.dlna.org"], probe.PROFILE)
                self.assertEqual(result.read(), data)
            self.assertEqual(reads, [len(data)])
            self.assertEqual((reads.heads, reads.gets, reads.denied), (1, 1, 0))
        with self.assertRaises(urllib.error.URLError):
            probe.HTTP.open(url, timeout=0.5)

    def testUnknownPathsAndOtherClientsCannotDownloadCredentials(self):
        data = probe.playlist_document(SONGS, URLS)
        with probe.serve_once(data, "127.0.0.1", "127.0.0.1") as (url, reads):
            with self.assertRaises(urllib.error.HTTPError) as error:
                probe.HTTP.open(url + "wrong", timeout=1)
            self.assertEqual(error.exception.code, 404)
            self.assertEqual(reads, [])
        with probe.serve_once(data, "127.0.0.1", "127.0.0.2") as (url, reads):
            with self.assertRaises(urllib.error.HTTPError) as error:
                probe.HTTP.open(url, timeout=1)
            self.assertEqual(error.exception.code, 404)
            self.assertEqual(reads, [])

    def testHandoffClosesServerBeforePlayAndNeverUsesNextToAdvance(self):
        renderer = RendererStub()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            probe.handoff(renderer, SONGS, URLS, "127.0.0.1")
        self.assertEqual(renderer.payload, probe.playlist_document(SONGS, URLS))
        self.assertEqual([a for a, _ in renderer.actions], [
            "Stop", "SetNextAVTransportURI", "SetAVTransportURI", "GetMediaInfo",
            "SetPlayMode", "GetTransportSettings", "Play"])
        self.assertEqual(renderer.actions[1][1]["NextURI"], "")
        self.assertNotIn("test-token", output.getvalue())
        self.assertNotIn("test-salt", output.getvalue())

    def testIncompleteOrUnreadPlaylistDoesNotStartPlayback(self):
        for renderer in [RendererStub(count=1), RendererStub(downloads=False)]:
            with self.assertRaises(probe.ProbeError):
                probe.handoff(renderer, SONGS, URLS, "127.0.0.1")
            self.assertNotIn("Play", [a for a, _ in renderer.actions])
            with self.assertRaises(urllib.error.URLError):
                probe.HTTP.open(renderer.url, timeout=0.5)

    def testRepeatModeCannotPassTheStopAtAlbumEndRequirement(self):
        renderer = RendererStub(mode="REPEAT_ALL")
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(probe.ProbeError):
            probe.handoff(renderer, SONGS, URLS, "127.0.0.1")
        self.assertNotIn("Play", [a for a, _ in renderer.actions])

    def testRendererEndpointsCannotRedirectCredentialsOffDevice(self):
        for url in ["http://192.168.1.11/control", "https://192.168.1.10/control", "http://user:pw@192.168.1.10/control"]:
            with self.assertRaises(probe.ProbeError):
                probe.renderer_url(url, "192.168.1.10")
        origin = urllib.parse.urlsplit("http://192.168.1.10:1234/description.xml")
        with self.assertRaises(probe.ProbeError):
            probe.renderer_url("http://192.168.1.10:5678/control", "192.168.1.10", origin)


if __name__ == "__main__":
    unittest.main()
