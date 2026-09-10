# TGSpeicher 3.2 – dein Telegram-Speicher für iOS

Native SwiftUI-App auf Deutsch für Dateien, Ordner, Tags, Fotos und Videos. Die App verbindet sich über TDLib direkt mit deinem Telegram-Konto. Dateien liegen in „Gespeichertes“, die Fotosicherung verwendet weiterhin den von dir gewählten Kanal. Kein zusätzlicher App-Server ist erforderlich.

## Neu in Version 3.2: Musik aus deinen Telegram-Ordnern

- **Eigener Musikbereich:** Bereits hochgeladene Audiodateien erscheinen automatisch. Nach Ordner filtern und nach Dateiname, eingelesenem Titel, Künstler oder Album suchen. Neue Dateien wie bisher unter „Dateien“ hochladen; der Player erzeugt keine zweite Telegram-Kopie.
- **Playlists:** Erstellen, umbenennen, Titel aus mehreren Ordnern auswählen, hinzufügen, entfernen und über „Bearbeiten“ umsortieren. Das Löschen einer Playlist oder einer Verknüpfung entfernt niemals das Original. Vorübergehend fehlende Dateien bleiben als nicht verfügbare Verknüpfung sichtbar.
- **Native Wiedergabe:** AVPlayer mit großer Liquid-Glass-Ansicht, eingebettetem Cover, Mini-Player über den fünf Tabs, veränderbarer Warteschlange, Zufallswiedergabe, Wiederholung, Positionsregler, Geschwindigkeit und Sleeptimer. Die bisherige Übersicht ist unter Einstellungen → Speicherübersicht erreichbar.
- **Systemintegration:** Audiowiedergabe im Hintergrund, Sperrbildschirm, Kopfhörersteuerung, AirPlay und Systemlautstärke. Abgezogene Kopfhörer pausieren; Anrufe und Audio-Unterbrechungen werden berücksichtigt. Die letzte Warteschlange und Position werden kontogebunden lokal gespeichert; beim Neustart beginnt keine automatische Wiedergabe.
- **Telegram-Streaming:** Dauerhafte Nachrichten-IDs werden beim Öffnen frisch in TDLib-Datei-IDs aufgelöst. Der Player fordert höchstens 512 KiB pro Lesevorgang an und prüft mit `getFileDownloadedPrefixSize`, ob die Bytes tatsächlich verfügbar sind. Auch verlustfrei aufgeteilte Dokumente werden über ihre Teilgrenzen hinweg gelesen. Abgebrochene Bereichsabrufe, Zeitüberschreitungen und Titelwechsel geben keine unbestätigten Dateibereiche als Audio aus.
- **Metadaten:** Eingebettete Titel-, Künstler- und Album-Tags sowie weitere von AVFoundation lesbare Text- und Zahlenfelder erscheinen unter „Titelinfo“. „Metadaten einlesen“ liest die Bibliothek nacheinander ein und ist stoppbar; dadurch werden noch nicht abgespielte Titel anhand ihrer Tags durchsuchbar. Cover werden verkleinert und begrenzt im Arbeitsspeicher gehalten, ohne den Telegram-Katalog mit Bildern aufzublähen.
- **Offline-Kopie:** Im großen Player über „… → Titel offline speichern“ die vollständige Datei herunterladen und prüfen. Die zusätzliche Player-Kopie ist anhand des Kontos, der Datei-ID und der Telegram-Teilnachrichten zugeordnet. „Offline-Kopie entfernen“ entfernt nur diese lokale Player-Kopie. Der normale Download bleibt unter „Dateien → Downloads“ verfügbar.

### Playlists sichern und wiederherstellen

Playlist-Namen, geordnete Datei-UUIDs, Text-Metadaten und Playlist-Löschmarkierungen gehören zum bestehenden komprimierten Telegram-Katalog. Die Originaldateieinträge enthalten weiterhin Chat-, Nachrichten- und Teil-IDs. Änderungen werden zuerst atomar lokal gespeichert und anschließend über die gemeinsame Katalogsicherung gesendet. Unter Musik ist außerdem **„Musikbibliothek jetzt in Telegram sichern“** verfügbar. Vor einer Deinstallation warten, bis diese Sicherung erfolgreich ist; ausschließlich lokale Änderungen, Wiedergabepositionen und Offline-Kopien sind kein Bestandteil der Telegram-Wiederherstellung.

Ältere v2/v3.0/v3.1-Kataloge bleiben importierbar und entfernen keine bereits vorhandene Musikbibliothek. Bei gleichzeitig bearbeiteten Playlists gewinnt die zuletzt bearbeitete Playlist-Version; dauerhaft gelöschte Playlist-IDs werden nicht aus alten Sicherungen wiederbelebt. Neue Playlists erhalten neue IDs. Bestehende Bundle-ID, Dateiablage, Upload-Protokolle und Schlüsselbund-Zugänge bleiben erhalten. **Version 3.2 über die vorhandene App installieren und dieselbe Signierung verwenden**, statt sie vorher zu löschen.

### Wiedergabegrenzen

Die App verwendet die nativen iOS-Decoder. MP3, AAC/M4A, ALAC, WAV, AIFF und FLAC hängen vom konkreten Container und Codec ab; insbesondere Ogg/Opus, WMA, beschädigte oder DRM-geschützte Dateien sind nicht allgemein garantiert. Nicht jede Datei enthält Cover oder vollständige Tags. Nicht unterstützte Codecs werden nicht automatisch konvertiert. Streaming benötigt die Verbindung zu Telegram; eine vollständige Offline-Kopie kann bei schlecht streambaren, aber nativ unterstützten Dateien helfen. Das Sperrbildschirmverhalten, Bluetooth, AirPlay und reale Telegram-Streams müssen zusätzlich auf einem signierten iPhone getestet werden; der CI-Build ersetzt diese Gerätetests nicht.

Die Offline-Funktion legt derzeit einzelne Titel gezielt ab; ein automatischer Download ganzer Playlists, ein Equalizer und garantiert lückenlose Albumübergänge gehören nicht zu Version 3.2. Ein Kontowechsel stoppt Wiedergabe und laufende Metadatenabrufe. Der bestehende Katalogabgleich muss nach dem Start erfolgreich abgeschlossen sein, bevor Wiedergabe oder Playlist-Änderungen freigegeben werden.

Technische Referenzen: [TDLib-Bereichsdownload](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1download_file.html), [vollständig verfügbare Dateibereiche prüfen](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1get_file_downloaded_prefix_size.html), [Apple: AVFoundation-Metadaten asynchron laden](https://developer.apple.com/videos/play/wwdc2021/10146/), [Apple: Now Playing und Systemsteuerung](https://developer.apple.com/videos/play/wwdc2022/110338/).

## Neu in Version 3.1

- **Premium automatisch erkennen:** `getMe.is_premium`, laufende TDLib-Updates und die Upload-Teilgrenzen aus `getApplicationConfig`. Unbekannter Kontostatus beginnt mit der Standardgrenze. Kontostatus und Schalter stehen unter Einstellungen → Dateigröße & Premium; erneute Prüfung beim Öffnen und regelmäßig vor weiteren Uploads.
- **Bis zu 4 GB pro Datei mit Premium:** Neue Dateien werden erst oberhalb von 4.000.000.000 Bytes geteilt, ohne Premium oberhalb von 2.000.000.000 Bytes. Niedrigere Servergrenzen haben Vorrang. Der Schalter kann Premium-Größen deaktivieren. Die Datei wird verlustfrei aufgeteilt, nicht abgeschnitten. Fotos als Telegram-Medien behalten Telegrams gesonderte Bildgrenzen.
- **Stabile Upload-Pläne:** Die Aufteilung wird vor dem ersten Senden gespeichert. Angefangene v3.0-Uploads behalten ihre 1,9-GB-Teilgrenzen. Wiederhergestellte Teilnachrichten geben die ursprüngliche Größe vor. Ein Premium-Wechsel während einer Übertragung ändert den Plan nicht; Telegram kann bei abgelaufenem Premium einen großen begonnenen Teil ablehnen, der dann zur Klärung angehalten bleibt.
- **Geordnetes Löschen:** Eine kontogebundene, lokale Löschwarteschlange sendet jeweils höchstens 100 eindeutige Nachrichten-IDs in einer Anfrage. Bestätigte Teilfortschritte bleiben gespeichert. Nach Neustart und Katalogabgleich wird fortgesetzt; bei Fehlern bleibt eine sichtbare Meldung mit „Erneut prüfen“. Der Katalogeintrag wird erst nach Bestätigung aller zugeordneten Nachrichten entfernt.
- **Ruhigere Bedienung:** Wischaktionen öffnen eine gemeinsame Bestätigung und entfernen die Zeile erst nach erfolgreichem Löschen. Die Detailansicht schließt danach. Bewusst gelöschte Fotos werden im jeweiligen Kanal von der automatischen Sicherung ausgeschlossen; diese Ausschlüsse gehören zum Telegram-Katalog. Lokale Originale werden dabei nicht gelöscht.
- **Neues App-Icon:** Ein eingebundenes 1024-Pixel-Icon mit Glasordner und Papierflieger für iPhone und iPad.

Das Löschprotokoll liegt lokal; eine Deinstallation während einer noch unvollständigen Löschung kann es entfernen. Daher Löschaufträge und die anschließende Telegram-Katalogsicherung vor einer Deinstallation abschließen. Bereits bestätigte Löschungen sind dauerhaft. Neue Tests prüfen zusätzlich Premium-Grenzen, Aufteilungs-Migration, partielle Löschungen, Kontowechsel, Rate-Limits und abgebrochene Dateivorbereitung.

Technische Referenzen: [Telegram Premium FAQ](https://telegram.org/faq_premium), [Upload-Teilgrenzen](https://core.telegram.org/api/files), [TDLib-Optionen](https://core.telegram.org/tdlib/options), [Nachrichten löschen](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1delete_messages.html).

## Mögliche nächste Funktionen

Noch nicht implementiert; kurze Ideen für weitere Ausbaustufen:

- **Telegram-Nachrichtenlinks teilen:** Direkte Verweise auf Dateien im Kanal; private Links erteilen anderen Personen keinen neuen Zugriff. Grundlage: [getMessageLink](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1get_message_link.html).
- **Dateikopien ohne erneuten Upload:** Vorhandene Telegram-Dateien serverseitig wiederverwenden, wenn Ziel und Zugriffsrechte es erlauben. Grundlage: [Resending existing files](https://core.telegram.org/api/files#resending-existing-files).
- **Angeheftete Offline-Dateien mit Speicherbudget:** Häufig gebrauchte Dateien gezielt verfügbar halten, übrige Download-Caches begrenzen. Grundlage: [TDLib optimizeStorage](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1optimize_storage.html).

## Was sich mit Version 3 ändert

- **Ein gemeinsamer Katalog:** Dateiverwaltung und Fotosicherung nutzen denselben Wiederherstellungszustand. Uploads starten erst, wenn der Telegram-Abgleich vollständig abgeschlossen ist. Verbindungsfehler gelten niemals als erfolgreiche Wiederherstellung.
- **Dauerhaftes Sendeprotokoll:** Vor dem Senden wird eine Absicht atomar auf dem Gerät gespeichert. Ein unklarer Ausgang wird anhand einer sichtbaren Vorgangskennung in Telegram geprüft. Ohne Klärung wird kein zweites `sendMessage` ausgelöst. Vorläufige und bestätigte Nachrichten-IDs werden getrennt behandelt.
- **Stabile Medienkennungen:** SHA-256 der vorbereiteten Mediendatei und der Zielkanal bestimmen ihre Kennung. Erneutes Einreihen derselben vorbereiteten Datei erzeugt dieselbe Kennung. Vorhandene Quellkennungen älterer Sicherungen bleiben nutzbar. Gleichnamige Dateien werden nicht allein anhand des Namens als identisch behandelt.
- **Fortsetzbare Dateiteile:** Bestätigte Teile werden bei einem Fehler nicht mehr gelöscht. Das Protokoll beziehungsweise die wiederhergestellten Teilinformationen ermöglichen ihre Wiederverwendung.
- **Versionierte Sicherungen:** LZFSE-komprimierte Kataloge mit SHA-256-Prüfsumme in „Gespeichertes“. Enthalten sind Ordner, Tags, Dateien, Kanäle, Nachrichten-IDs, vollständige Scan-Grenzen und Löschmarkierungen. Ältere Telegram-Sicherungen werden nicht automatisch entfernt.
- **Manuelle Wiederherstellung:** Katalog als `.tgscatalog` exportieren, teilen und wieder importieren; ältere v2-JSON-Kataloge und lokale Katalogdateien importieren; Katalog- oder Verweis-Nachrichten-ID eingeben. Ein Import wird geprüft und zusammengeführt. Eine lokale Rückfallkopie wird vorher angelegt.
- **iCloud-Schlüsselbund:** Kleine, kontogebundene Verweise auf Sicherungskanal, Katalog und Verweisnachricht. Der vollständige Katalog bleibt in Telegram. Zugangsdaten und TDLib-Schlüssel werden dadurch nicht zu einem Cloud-Katalog umfunktioniert.
- **Deutsch und iOS:** Deutsche Navigation, Dialoge, Statusmeldungen und Systemberechtigungstexte; ruhigere Hintergründe, native Listen und dezente Material-/Liquid-Glass-Elemente. Bestehende Dateipfade behalten ihre Namen, damit lokale Dateien weiter gefunden werden.

## Benutzung und Umstieg

1. Die neue App möglichst zunächst **über die bestehende Installation installieren**, mit derselben Bundle-ID und Signierung. Dadurch bleiben bisherige lokale Metadaten verfügbar.
2. Mit demselben Telegram-Konto anmelden und den Katalogabgleich abwarten. Bei der ersten Migration oder einem vollständigen Scan kann das je nach Verlauf dauern.
3. Unter **Fotos** den bisherigen Sicherungskanal prüfen. Falls weder Katalog noch Schlüsselbund den Kanal kennen, den bestehenden Kanal erneut auswählen; keinen neuen Kanal allein wegen einer fehlenden lokalen Datenbank anlegen.
4. Unter **Einstellungen → Sichern & Wiederherstellen → Jetzt in Telegram sichern** eine aktuelle Sicherung erstellen. Zusätzlich **Katalog als Datei exportieren** und die Datei außerhalb der App ablegen.
5. Anschließend die Fotosicherung starten. Pause/Neustart verwenden die bestehende Warteschlange. Fehlgeschlagene beziehungsweise unklare Übertragungen lassen sich unter **Übertragungen** erneut prüfen.
6. Nach einer Neuinstallation zuerst denselben Account und Kanal wiederherstellen. Wenn die automatische Suche nicht reicht, die exportierte Katalogdatei importieren oder die Nachrichten-ID verwenden.

Vor dem Entfernen gesicherter Originale vom iPhone muss die Telegram-Dateiprüfung erfolgreich durchlaufen. Die App prüft dabei die Erreichbarkeit aller zugeordneten Telegram-Nachrichten; das ist keine erneute vollständige Prüfsummenprüfung jedes Fotooriginals.

## Architektur

| Modul | Aufgabe |
| --- | --- |
| `Recovery/RecoveryCore.swift` | Archivformat, begrenzte Dekompression, Prüfsummen, Validierung, Zusammenführung, stabile Medien-ID |
| `Recovery/DurableOutbox.swift` | Atomare Sendeabsichten, vorläufige IDs, bestätigte IDs, konservativer Abgleich vor Wiederholung |
| `Recovery/CloudRecovery.swift` | Snapshot-Suche mit Rückfall auf ältere Versionen, kontogebundener Import, paginierter Kanalabgleich |
| `Recovery/RecoveryCenterView.swift` | Sicherungsstatus, Export, Import, Nachrichten-ID und Schlüsselbund-Verweise |
| `Music/MusicModels.swift` | Musik-Katalog, Playlist-Zusammenführung, validierte 64-Bit-Bereichsplanung und Warteschlange |
| `Music/TelegramAudioResource.swift` | Abgesicherte, abbrechbare Telegram-Bereichsabrufe für AVPlayer |
| `Music/MusicPlayer.swift` | Native Audio-Session, Metadaten, Offline-Kopien und Systemsteuerung |
| `Music/MusicViews.swift` | Deutscher Musikbereich, Playlists, Mini-Player und große Playeransicht |
| `CloudStore.swift` | Gemeinsamer Dateikatalog, Übertragungen und zeitlich gebündelte Snapshots |
| `UploadQueue.swift` | Persistente Warteschlange, Dateibereitstellung, Hashing, Kontozuordnung |
| `PhotoBackupManager.swift` | Photos-/iCloud-Export, lokale Fotozuordnungen, Nachtmodus; kein konkurrierender Telegram-Fotokatalog mehr |

Katalogsicherungen laufen zwischen Dateiübertragungen, bei kontinuierlichen Uploads ungefähr alle 45 Sekunden, sobald eine laufende Datei abgeschlossen ist. Metadatenänderungen und manuelle Sicherungen werden bevorzugt. Ein Snapshot wird aus einem festen Stand erstellt; währenddessen hinzukommende Änderungen lösen eine weitere Sicherung aus. Nach einem Start wird die Lücke seit der gespeicherten Nachrichten-ID nachgelesen, ohne Zeitstempel als Abbruchkriterium zu verwenden. Vollständige Scans haben keine künstliche Grenze von 20.000 Nachrichten.

Lokale Kataloge besitzen eine vorherige Version als Rückfallkopie. Katalogimporte sind auf 128 MB begrenzt; die Dekompression hat ebenfalls eine feste Größenobergrenze. Nachrichten-IDs sind die dauerhaften Referenzen. Die nur für eine TDLib-Sitzung gültigen Datei-IDs werden bei einer Wiederherstellung verworfen und beim Abruf neu ermittelt.

## Grenzen, die für die Wiederherstellung zählen

- Telegram bietet hier keine transaktionsübergreifende Exactly-once-Garantie für mehrere gleichzeitig hochladende App-Installationen. Für eine Mediathek sollte **eine Installation gleichzeitig sichern**. Das Protokoll verhindert automatische Wiederholungen bei unklarem Ausgang, kann dann aber einen manuellen Abgleich erfordern.
- Wenn ein Original neu codiert oder bearbeitet wird, kann sich der Inhalts-Hash ändern. Das ist keine Garantie, visuell identische, aber unterschiedlich codierte Bilder zu erkennen. Bereits vorhandene physische Telegram-Duplikate werden nicht automatisch gelöscht.
- Nach einer Deinstallation lassen sich bereits in Telegram gespeicherte Dateien und Metadaten wiederherstellen. Ausschließlich lokal vorhandene, noch nicht gesendete Dateien und noch nicht remote gesicherte Änderungen können dadurch nicht zurückgeholt werden. Ohne lesbaren Katalog lassen sich aus Mediennachrichten nicht immer ursprüngliche Ordnernamen und Tags rekonstruieren; dann erscheinen Wiederherstellungsordner.
- Eine gelöschte Telegram-Nachricht, ein verlorenes Konto oder ein nicht mehr zugänglicher Kanal kann durch einen Katalog nicht ersetzt werden. Ein gespeicherter Katalog ist ein Verzeichnis, keine zweite Kopie der Mediendaten.
- iCloud-Schlüsselbund muss verfügbar sein. Zugriff nach Neuinstallation beziehungsweise auf weiteren Geräten hängt auch von Apple-Account, Bundle-ID und Signierung/Entitlements ab. Die App zeigt das Ergebnis des lokalen Schlüsselbund-Schreibens; sie kann die serverseitige iCloud-Zustellung nicht bestätigen.
- iOS kann die App im Hintergrund anhalten. Der Nachtmodus funktioniert am zuverlässigsten bei geöffneter App und Stromversorgung; ein unbegrenzter Hintergrunddienst wird nicht versprochen.

## Build und Tests

Jeder Pull Request gegen `main` und jeder Push auf `main` führt den macOS-Workflow aus:

1. Eigenständige Swift-Regressionstests für Katalogformat, Beschädigung, Kontotrennung, Ordnerstruktur, Migration, Sendeabbruch, Wiederholung und Schreibfehler; zusätzlich Playlist-Migration/-Konflikte/-Löschung, 4-GB-Bereichsplanung, unvollständige Audiodownloads und Wiedergabereihenfolge.
2. XcodeGen und die fest gepinnte TDLibFramework-Version.
3. Release-Build für iPhone und iPad ab iOS 17; Liquid Glass ab iOS 26.
4. Paket **`TGSpeicher-v3.2.0-unsigned.ipa`** als Actions-Artefakt.

Die IPA muss vor der Installation mit deiner Apple-ID beziehungsweise deinem Zertifikat signiert werden. Der Workflow verändert oder committet keinen App-Code mehr automatisch. Tests verwenden simulierte Telegram-Antworten; ein realer Telegram-/iCloud-/Neuinstallationsdurchlauf auf einem iPhone bleibt ein separater Gerätetest.

Technische Grundlagen: [TDLib-Sendeereignisse](https://core.telegram.org/tdlib/getting-started), [TDLib-Nachrichtensuche und Pagination](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1search_chat_messages.html), [Apple: synchronisierbare Schlüsselbund-Einträge](https://developer.apple.com/documentation/security/ksecattrsynchronizable).
