# MusiCards – Navidrome → AVM fejlesztési átadás

Dátum: 2026-08-10

Ez a dokumentum a MusiCards tervezése közben elvégzett helyi hálózati kísérleteket és az ezekből levont következtetéseket foglalja össze. Elsődleges célja, hogy egy másik Codex-beszélgetésben vagy fejlesztői környezetben innen lehessen folytatni a munkát.

## A rendszer

- Raspberry Pi 5, Umbrel alatt
- Navidrome: `http://umbrel.local:4533`
- AVM Audio CS 2.3 streamer: `192.168.0.186`
- Vezérlőként a Macen futó parancssori Python-próbák szolgáltak
- A lejátszandó fájlokat a Navidrome szolgálta ki
- Az AVM közvetlenül a Raspberry Pi-ről töltötte le a hangfájlt; a Mac csak UPnP control point volt

## A tervezett MusiCards-források és kimenetek

Források:

1. Helyi fájl, például USB SSD-ről → iPhone vagy Mac
2. Navidrome helyi hálózaton → iPhone vagy Mac
3. Navidrome interneten/Tailscale-en keresztül → iPhone vagy Mac
4. Navidrome helyi hálózaton → AVM; az iPhone vagy Mac csak irányít

Következtetés: az eddigi eredmények alapján nem szükséges külön MiniDLNA szervert futtatni kizárólag az AVM miatt. A Navidrome képes a fájlt HTTP-n kiszolgálni, a MusiCards pedig a kapott stream URL-t átadhatja az AVM UPnP AVTransport szolgáltatásának.

## Bizonyított eredmények

### 1. A Navidrome raw stream közvetlenül lejátszható az AVM-en

A Navidrome Subsonic API-jából kiválasztott szám `stream` végpontját az AVM elfogadta:

```text
/rest/stream.view
    ?u=<username>
    &t=<salted-token>
    &s=<salt>
    &v=1.16.1
    &c=<client-name>
    &id=<song-id>
    &format=raw
    &maxBitRate=0
```

A sikeresen kipróbált fájlok M4A/AAC állományok voltak (`audio/mp4`). Az AVM a Navidrome URL-jét közvetlenül kérte le, tehát a Mac nem továbbította és nem transzkódolta a hangot.

### 2. A Navidrome támogatja az AVM számára szükséges HTTP Range kérést

A raw stream ellenőrzésekor:

```text
HTTP 206
Content-Type: audio/mp4
Content-Range: bytes 0-0/<teljes-méret>
```

Ez fontos a seek és a stabil hálózati lejátszás számára.

### 3. Az AVM UPnP MediaRenderer felderíthető és vezérelhető

A próba által talált adatok:

```text
Renderer: AVM Audio CS 2.3
AVTransport: version 2
Control URL:
http://192.168.0.186:41312/Control/LibRygelRenderer/RygelAVTransport
```

Az AVM eszközleírásának akkor működő URL-je:

```text
http://192.168.0.186:41312/9e162908-55d4-45b2-93db-7fd295ee46de.xml
```

A port és esetleg a leíró URL újraindítás után megváltozhat. A végleges alkalmazásnak SSDP-vel kell felderítenie, és csak gyorsítótárként érdemes megőriznie a korábbi URL-t.

Egy alkalommal az SSDP nem adott választ, a következő futtatás viszont azonnal sikerült. Emiatt célszerű több próbálkozást, unicast SSDP-t és a legutóbbi leíró URL ellenőrzését kombinálni.

### 4. A szabványos UPnP AVTransport lejátszás működik

A következő sorrend bizonyítottan elindította a zenét:

1. `SetAVTransportURI`
2. `Play`

Az AVM kijelzőjén megjelent a szám és az album metaadata is.

### 5. A `SetNextAVTransportURI` működik

Két véletlen Navidrome-számmal végrehajtott sikeres teszt:

1. Első szám átadása `SetAVTransportURI`-val
2. Következő szám előkészítése `SetNextAVTransportURI`-val
3. `GetMediaInfo` segítségével visszaellenőrizhető volt a következő URI
4. `Play`
5. Seek az első szám utolsó 12 másodpercére
6. Az AVM a szám végén önállóan átváltott a következő Navidrome-streamre

A terminál eredménye:

```text
SetNextAVTransportURI elfogadva és visszaolvasható.
Az első szám lejátszása elindult.
Seek elfogadva.
SIKER: az AVM önállóan átváltott a második Navidrome-számra.
A SetNextAVTransportURI-alapú folyamatos lejátszás bizonyított.
```

Ez a legfontosabb eredmény. A MusiCardsnak nem kell a teljes albumot az AVM memóriájába töltenie. Elég egy mozgó, két elemes ablak:

- `CurrentURI`: az éppen játszott szám
- `NextURI`: a következő szám

Amikor a következő szám currentté válik, a MusiCards előkészíti az azután következőt. Ez szabványosabb és várhatóan stabilabb, mint egy gyártóspecifikus queue.

## QPlay-kísérlet – elvetve

Az AVM eszközleírása hirdetett egy Tencent `QPlay` szolgáltatást és akár 50 000 trackes queue-t. A QPlay eredetileg a QQ Music kínai streaming ökoszisztémához készült, nem általános DLNA/UPnP lejátszási szabvány.

A teljes album QPlay-queue-ba történő beszúrásánál:

- az AVM elfogadta és kijelezte az album- és trackadatokat;
- a queue állítólag 36/36 számot tárolt;
- a tényleges lejátszás nem indult el;
- az AVM/app átmeneti, „homokórázó” állapotba került;
- a `Next` parancsok csak a kijelzett tracksorszámot változtatták, hang nem indult.

Következtetés: a QPlay-ágat nem érdemes tovább fejleszteni. A MusiCards implementációja kizárólag szabványos UPnP AVTransport műveletekre épüljön.

## Javasolt prototípus

A következő lépés egy kicsi, külön futtatható SwiftUI `Renderer Lab` target a meglévő MusiCards Xcode-projektben. Ne külön repository legyen: együtt, de a fő alkalmazástól elválasztva fejlődjön.

Első körben szükséges funkciók:

- Navidrome-bejelentkezés és albumválasztás
- AVM-felderítés SSDP-vel
- eszköz- és szolgáltatásleírás feldolgozása
- `SetAVTransportURI`, `SetNextAVTransportURI`
- `Play`, `Pause`, `Stop`, `Seek`, `Next`, `Previous`
- `GetTransportInfo`, `GetPositionInfo`, `GetMediaInfo`
- az aktuális és a következő szám kijelzése
- részletes hálózati/SOAP napló
- alkalmazás előtérbe kerülésekor teljes állapot-újraszinkronizálás

### Háttér és „Spotify Connect-szerű” viselkedés

A lejátszás az AVM-en folyik, ezért az iOS/macOS alkalmazás bezárása vagy háttérbe kerülése nem szakítja meg az aktuális streamet, és az előre betöltött következő számra való átmenetet sem.

Amikor az alkalmazás újra előtérbe kerül:

1. újra felderíti vagy ellenőrzi a renderert;
2. lekéri a `GetTransportInfo`, `GetPositionInfo` és `GetMediaInfo` állapotot;
3. az URI-ból vagy a DIDL-Lite metaadatból azonosítja a Navidrome-számot;
4. helyreállítja a Now Playing felületet;
5. szükség esetén ismét beállítja a következő tracket.

Kezdetben 1–2 másodperces polling elegendő. Később UPnP event subscription/GENA használható a gyorsabb állapotfrissítéshez.

## Fontos műszaki megjegyzések

### „Bit-perfect” jelentése ebben a rendszerben

A `format=raw&maxBitRate=0` azt célozza, hogy a Navidrome az eredeti fájlt transzkódolás nélkül adja át. Az eddigi teszt azt bizonyítja, hogy az AVM közvetlenül ezt a raw HTTP-erőforrást játssza le.

A teljes bit-perfect állításhoz még külön ellenőrizendő:

- FLAC, ALAC, WAV, AIFF, AAC/M4A támogatás;
- mintavételi frekvenciák és bitmélységek;
- az AVM belső DSP/volume beállításai;
- hogy a Navidrome semmilyen formátumnál nem választ transzkódolást.

### Hitelesítési adatok az URL-ben

A Subsonic stream URL felhasználónevet, saltot és salted MD5 tokent tartalmaz. Az AVM-nek ezt az URL-t át kell adni, hogy közvetlenül lekérhesse a fájlt. Megbízható helyi hálózaton ez prototípushoz elfogadható, de az URL-eket nem szabad naplóban vagy analitikában tartósan tárolni.

Az AVM-lejátszás csak helyi hálózatra tervezett. A Tailscale/internetes Navidrome-lejátszás az iPhone/Mac helyi lejátszási útvonala; az AVM-et nem kell az internet felől elérhetővé tenni.

## A működő, QPlay nélküli reprodukció

A dokumentum mellé tartozó fájl:

```text
navidrome_avm_setnext_probe.command
```

Futtatás Terminalból:

```bash
chmod +x navidrome_avm_setnext_probe.command
./navidrome_avm_setnext_probe.command
```

A script:

- nem használ QPlayt;
- két véletlen Navidrome-számot választ;
- ellenőrzi a raw streamet és a Range támogatást;
- megkeresi az AVM AVTransport szolgáltatását;
- beállítja a current és next URI-t;
- elindítja az első számot;
- kérésre az utolsó 12 másodpercre ugrik;
- figyeli, hogy az AVM önállóan átvált-e a második számra.

## Rövid döntési összefoglaló

- Egyetlen médiaszerverként a Navidrome ígéretes és az eddigi AVM-próbák alapján életképes.
- Az AVM számára nem szükséges a Navidrome protokoll natív támogatása: az AVM egyszerű HTTP URL-t kap UPnP-n keresztül.
- MiniDLNA csak tartalék lehetőség, jelenleg nincs rá bizonyított szükség.
- QPlayt el kell engedni.
- A stabil irány a szabványos AVTransport + `SetNextAVTransportURI` mozgó queue.
- Következő fejlesztési lépés: külön `Renderer Lab` target a MusiCards Xcode-projektben, majd a bizonyított réteg integrálása a fő alkalmazásba.

