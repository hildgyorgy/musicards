# MusiCards – Következő fejlesztési irányok

Ez a dokumentum a 2026 augusztusi review-beszélgetés négy megbeszélt "vágyát" foglalja össze: mit jelentenek technikailag, mi van már meg hozzájuk a kódban, mit kell hozzáadni, és milyen sorrendben érdemes nekik nekiállni.

---

## 1. Bitperfekt lejátszás (rövid jelút, hog mode, integer)

**Cél:** valódi, kizárólagos hozzáférésű, minimális jelúthosszú lejátszás egy kiválasztott DAC-ra – nem csak "jó ráta", hanem garantáltan senki más nem nyúl bele az eszközbe lejátszás közben.

### Ami már megvan

- A `MacSystemPlaybackEngine` már végez **adaptív mintavételi ráta-illesztést**: `matchDefaultOutputSampleRate` a `kAudioDevicePropertyNominalSampleRate`-et állítja át a track natív rátájára, majd visszaállítja eredetire.
- Az `AudioOutputTransport` enum már megkülönbözteti a transport-típusokat, és `allowsDeviceSampleRateMatching`-gel kizárja a Bluetooth/AirPlay-t a ráta-illesztésből.
- 16/24 bites forrásoknál (a teljes Picard-taggelt könyvtár) a Float32 köztes reprezentáció **bizonyíthatóan bitpontos** – ez nem elméleti, hanem matematikai tény (24 bites egész pontosan, kerekítés nélkül fér Float32 mantisszájába).

### Ami hiányzik

1. **Hog mode** (`kAudioDevicePropertyHogMode`) – kizárólagos hozzáférés az eszközhöz, hogy más app/rendszerhang ne tudjon belekeverni.
2. **`DefaultOutput` helyett `HALOutput` + explicit eszközkötés** (`kAudioOutputUnitProperty_CurrentDevice`) – a `DefaultOutput` megosztott, "rendszer default"-ot követő kimenet, nem kizárólagos. Bitperfekt módban a user explicit módon választ ki egy konkrét eszközt.
3. **Eszközlista enumerálása** (`kAudioHardwarePropertyDevices` a `kAudioObjectSystemObject`-en, kiszűrve a kimeneti-stream nélküli eszközöket) + egy picker UI a Settings-ben, **csak macOS-en**.
4. **Hot-plug kezelés** – property listener a `kAudioHardwarePropertyDevices`-re (eszközlista-változás) és a kiválasztott eszköz `kAudioDevicePropertyDeviceIsAlive`-jára (lecsatlakozás → szép fallback megosztott módba, nem hibaüzenet).
5. **Pop-mentes összerakási sorrend**: stop → esetleges korábbi hog elengedése → nominal rate beállítás → rövid, szándékos néma szünet (~200–500 ms, amíg a DAC PLL-je relockol) → hog megszerzése → `HALOutput` eszközhöz kötése + stream format → indítás.
6. **Natív integer formátum végigvitele** (opcionális, "defense in depth") – jelenleg Float32 köztes réteg van, ami 16/24 bitnél bizonyítottan egzakt; a natív integer formátum kizárólag akkor adna érdemi biztonságot, ha valaha 32 bites forrás kerülne a könyvtárba (gyakorlatilag nem jellemző egy személyes riprelt gyűjteményben).
7. **Diagnosztika** – a tényleges megszerzett ráta/hog-állapot logolása minden lejátszás-indításnál, ugyanabban a mintában, mint a `RemotePlaybackDiagnostics.logger` – hogy ne hinni kelljen, hanem látni a bitperfekt állapotot.

### Hova illeszkedik

Bővítés a **meglévő `MacSystemPlaybackEngine`-en belül**, nem új `PlaybackEngine`-konformer – a decode/render pipeline változatlan marad, csak az eszközkonfigurációs réteg bővül. Egy kis dedikált típus (`ExclusiveOutputController` vagy hasonló) kapszulázza a hog/device-binding logikát, az `AudioOutputRouteInspector` konvencióját követve.

### Platform

**Csak macOS.** iOS-en nincs HAL-szintű exclusive access/hog mode megfelelője – ott legfeljebb `AVAudioSession.preferredSampleRate` + `.measurement` kategória adható "best effort" címkével, garantált kizárólagosság nélkül.

**Nehézség: Közepes.** Jórészt additív, jól elszigetelt a `PlaybackController`/UI rétegtől.

---

## 2. UPnP kontroller (Navidrome ↔ renderer, pl. AVM CS 2.3)

**Cél:** a Navidrome-könyvtárból UPnP-n keresztül vezérelni egy dedikált rendert (pl. AVM CS 2.3) – az app **kizárólag kontroller és kijelző**, semmilyen audio-adat nem megy át rajta, se a Mac-et, se a telefont nem terheli.

### A döntő egyszerűsítés

A user explicit döntése, hogy **csak Navidrome-forrás menjen UPnP-n**, kihagyja a legbonyolultabb részt: nem kell helyi fájlokat kiszolgáló beágyazott HTTP-szervert építeni. A Navidrome `/rest/stream?...&format=raw` URL-je – amit ma a `HTTPRandomAccessByteSource` fogyaszt – **egy az egyben átadható** a renderer `SetAVTransportURI` akciójának; a renderer közvetlenül a Navidrome szerverről húzza le a bájtokat.

### Miért illeszkedik jól az architektúrába

A `PlaybackEngine` protokoll (`prepare`/`play`/`pause`/`stop`/`seek`/`eventHandler`) UPnP-vezérlésre szinte ráhúzható – a `PlaybackController` és a MusicBrainz-alapú UI **egy sort sem változna**, csak egy új konformer kerül be:

```
UPnPPlaybackEngine: PlaybackEngine
  prepare(item) → SetAVTransportURI + DIDL-Lite metaadat
  play()/pause()/stop() → megfelelő AVTransport akciók
  seek(to:) → Seek akció (REL_TIME)
  háttérben → GetPositionInfo/GetTransportInfo pollozás → .positionChanged/.finished események
```

### Építőelemek

1. **SSDP discovery** – UDP multicast M-SEARCH (`239.255.255.250:1900`), `urn:schemas-upnp-org:service:AVTransport:1` service type-ra. A `LOCATION` header egy XML device-description URL-re mutat, abból jönnek a `controlURL`-ek.
2. **AVTransport SOAP kliens** – sima HTTP POST + XML envelope, nincs rá exotikus keretrendszer szükség. Stílusban az `OpenSubsonicClient`/`OpenSubsonicRequestBuilder` mintáját érdemes követni.
3. **DIDL-Lite metaadat generálás** a `CurrentURIMetaData` argumentumhoz (cím, előadó, album, időtartam, MIME-típus) a meglévő MusicBrainz-adatokból – a renderer saját kijelzőjén/appjában is helyesen fog megjelenni a szám.
4. **Státuszfrissítés pollozással** – kezdésnek elég `GetPositionInfo`/`GetTransportInfo` kb. 1 mp-enként, ugyanabban a mintában, mint a meglévő progress-timer a Mac/iOS motoroknál. A "helyes" UPnP-módszer (GENA SUBSCRIBE/NOTIFY, saját callback-HTTP-szerverrel) bonyolultabb – csak akkor érdemes belevágni, ha a pollozás ténylegesen nem elég pontosnak bizonyul.
5. **iOS Local Network engedély** (`NSLocalNetworkUsageDescription`) SSDP-hez; ha sandboxolt az app, `com.apple.security.network.client` entitlement is kellhet.

### Bónusz

Az AVTransport spec ismeri a `SetNextAVTransportURI` akciót – ha az AVM támogatja, ezzel a renderer **saját maga** old meg egy zökkenőmentes átmenetet a következő számra, vissza sem kell szólnia a kontrollerhez. Ez közvetlenül kapcsolódik a 3. ponthoz (gapless).

**Nehézség: Közepes-nagy.** Nulláról épülő protokoll-kliens (SSDP + SOAP), de architektúrálisan tisztán elszigetelt – nem nyúl a meglévő lejátszó-motorokhoz vagy a UI-hoz.

---

## 3. Gapless playback (local / Navidrome / UPnP)

**Cél:** hallható rés nélküli átmenet számok között, minden lejátszási útvonalon.

### Jelenlegi állapot – nincs semmi előkészítve

A `PlaybackController` track-váltása ma **100%-ban reaktív**:

```
.finished esemény → selectNext(autoplay: true) → selectItem(...)
  → engine.stop()                    // leállítja a jelenlegi AudioUnit-ot
  → play()
      → resolvedItem(currentItem)    // csak MOST kezdődik az asset feloldása
      → engine.prepare(resolvedItem) // csak MOST nyílik meg a dekóder, csak MOST tölt fel a puffer
      → engine.play()                // csak MOST épül újra az AudioUnit
```

Semmi nem készül elő a következő számból, amíg az előző teljesen el nem fogyott. Ez minden váltásnál garantált rést jelent – helyi fájlnál kisebbet, Navidrome-nál (hálózati kör-utak miatt) jóval nagyobbat.

### Két réteg

1. **Előretöltés/előfeloldás** – a `PlaybackEngine` protokoll bővítése egy `prepareNext(_:)`-szerű metódussal: egy második, párhuzamosan élő dekóder nyitása és primelése az aktuális szám lejátszása *alatt*. Ez elsősorban a Navidrome-útvonalnál nagy nyereség, mert ott ma a teljes asset-feloldás és az első HTTP-kérések dominálják a rést.
2. **Zökkenőmentes átadás motor-szinten** – a render callback (`MCPPCMRenderCallback`) az egyik `DecodedPCM` gyűrűspufferéről a másikra váltson **AudioUnit-leállítás nélkül**, pontosan az utolsó minta elfogyásakor. Ez a C-szintű `MCPPCMRenderer`-t és a Mac/iOS motorok állapotgépét is érinti – ez a ténylegesen nehéz rész.

### Backend-enkénti eltérés – ez nem egy feladat, hanem három

- **Helyi Core Audio-lejátszás**: mindkét réteg kell, ez a legnehezebb (a motor állapotgépének átépítése).
- **Navidrome, ha közvetlenül az app Core Audio motorján megy** (nem UPnP-n át): ugyanaz a két réteg kell, mint helyinél, mert ugyanazon a `MacSystemPlaybackEngine`-en fut át.
- **UPnP**: potenciálisan a **legolcsóbb** – ha a renderer támogatja a `SetNextAVTransportURI`-t, maga a renderer végzi a váltást, a kontrollernek szinte semmit nem kell tennie.

### Fontos korlát – kapcsolódás a bitperfekt ponthoz

Ha bitperfekt/kizárólagos mód aktív, és két egymást követő szám **eltérő mintavételi rátájú**, a valódi gapless fizikailag lehetetlen resampling nélkül. Ilyenkor vagy sérül a bitperfekt elv, vagy vállalni kell egy rövid, tudatos csendet az eszköz-ráta újraszinkronizálásához – ez egy valós tervezési kompromisszum, nem hiányosság.

**Nehézség: Legnagyobb, és nem egységes.** A UPnP-ág könnyű lehet, a Core Audio-ág (helyi + Navidrome-appon-belül) valódi motor-szintű munka.

---

## 4. My Library ↔ teljes MusicBrainz katalógus váltás

**Cél:** explicit váltási lehetőség "csak amit birtoklok" és "teljes MusicBrainz katalógus feltérképezése" nézetek között.

### Jelenlegi állapot

- **Keresési lista**: blendelt, nem választható szét – a `SearchViewModel`-ben a `mergeLibraryFirst`/`stablePlayableFirst` mindig library-first sorrendben mutatja a MusicBrainz- és library-találatokat együtt.
- **Artist-oldal** (`loadArtist` a `MusiCardsAppModel`-ben): meglepő, jó hír – ez **már most is 100%-ban tiszta MusicBrainz-katalógus**, semmilyen library-szűrés nincs rajta. A "teljes katalógus exploration" élmény tehát ott már eleve létezik.

### A munka

A fő bizonytalanság itt **nem technikai, hanem termékdöntés**: meddig terjedjen ki a "My Library" mód?

- **Szűken (csak a keresési lista)** – kicsi feladat: egy mód-flag, ami "My Library" módban kihagyja a MusicBrainz-lekérdezést, és csak a `libraryReleaseRows`-t mutatja. A legtöbb alapkő (`libraryManager.containsRelease`, a meglévő merge-logika) már megvan hozzá.
- **Kiterjesztve (artist-oldal, release-group verzió-böngészés is)** – közepes feladat: owned/not-owned szűrést kellene bevezetni olyan helyeken, ahol ma egyáltalán nincs.

**Javaslat:** szűken indulni (csak a keresés), és csak akkor bővíteni, ha használat közben tényleges hiányérzet jelentkezik.

**Nehézség: Kicsi–közepes**, attól függően, mennyire terjed ki a mód a keresésen túlra.

---

## Javasolt sorrend

A sorrend nem véletlenszerű – tényleges függőségekre és kockázat-elszigetelésre épül.

1. **My Library/katalógus váltás** – nem nyúl a törékeny lejátszó-motorhoz, gyors siker, és a termékdöntést (mennyire terjedjen ki) olcsó kipróbálni és módosítani, amíg még kicsi a felület.

2. **Bitperfekt** – ez adja meg a lejátszó-motorban azt az alap-primitívet ("azonos rátájú szám → gyors váltás, eltérő rátájú → tudatos, rövid csend"), amire a gapless (4. pont) építeni fog. Ha ezt előbb csináljuk meg és teszteljük önmagában, a gapless-nél egy bevált, stabil eszköz-konfigurációs réteg fölé építünk, nem egyszerre két mozgó alkatrészt hegesztünk össze.

3. **UPnP kontroller** – teljesen független a Mac/iOS motor belső állapotától, technikailag bármikor jöhetne, akár párhuzamosan is a 2. ponttal. A 2. és 3. közötti sorrend nem architektúra kérdése, hanem érdeklődés/prioritás kérdése – nincs köztük technikai függőség.

4. **Gapless** – ez a legköltségesebb és legkockázatosabb belenyúlás a motor belsejébe, ezért utoljára. Két dolog is megkönnyíti, ha addigra megvan: a bitperfekt munkából örökölt ráta-váltási logika (2. pont), és a UPnP motor, aminél a gapless jó eséllyel szinte ingyen adódik a `SetNextAVTransportURI`-ból (3. pont). Ha ezt csinálnánk először, kétszer nyúlnánk hozzá ugyanazokhoz a fájlokhoz, feleslegesen.

Mind a négy önállóan is értékes munkacsomag – nem kell egyben megcsinálni, és a sorrend pont azt szolgálja, hogy egyik se dolgozzon a másik ellen menet közben.
## macOS alatt esetleg egy “miniplayer” nézet

