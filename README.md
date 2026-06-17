# WG26Scan

Kamerový modul pro optický scan řeziva (WoodGrader 26 sesterská appka).
Manuální zámek ISO/expozice/ohniska + sériové snímání v nastavené frekvenci.

## Build (bez Macu)

Tento repo obsahuje `project.yml` (XcodeGen) a GitHub Actions workflow,
který na macOS runneru vygeneruje Xcode projekt a zkompiluje nepodepsané
`WG26Scan.ipa`. Výsledek najdeš v záložce **Actions** -> poslední běh ->
**Artifacts** -> `WG26Scan-unsigned-ipa`.

## Instalace na iPhone přes AltStore (Windows)

1. Stáhni a nainstaluj [AltServer](https://altstore.io/) na Windows PC
   (vyžaduje ovladače Apple Mobile Device - stačí mít nainstalovaný iTunes
   nebo "Apple Devices" z Microsoft Store).
2. Připoj iPhone k PC kabelem, spusť AltServer (běží v system tray).
3. Při prvním spuštění z AltServer ikony v tray zvol **Install AltStore**
   a vyber svůj iPhone - tím se na telefon nainstaluje AltStore appka
   (potvrď v telefonu Nastavení -> Obecné -> VPN a správa zařízení ->
   důvěřovat vývojateli).
4. Stáhni `WG26Scan.ipa` z GitHub Actions artefaktu.
5. V system tray klikni na AltServer -> **Install .ipa** -> vyber soubor
   a svůj iPhone. AltServer appku přihlásí tvým Apple ID a podepíše ji.
6. Po 7 dnech podpis vyprší (limit bezplatného Apple ID) - appku stačí
   znovu nainstalovat stejným postupem, nebo má AltStore appka v telefonu
   tlačítko "Refresh All", pokud je AltServer puštěný na stejné Wi-Fi.

## Struktura výstupu skenu

Každá série snímků se uloží do `Documents/scan_<timestamp>/` jako
`frame_0000.heic`, `frame_0001.heic`, ... + `metadata.json` s ISO,
časem závěrky, pozicí ohniska a timestampem každého snímku.
