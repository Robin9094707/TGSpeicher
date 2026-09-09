# TGSpeicher 3.0 – dein Telegram-Speicher für iOS

Native SwiftUI-App auf Deutsch für Dateien, Ordner, Tags, Fotos und Videos. Die App verbindet sich über TDLib direkt mit deinem Telegram-Konto. Dateien liegen in „Gespeichertes“, die Fotosicherung verwendet weiterhin den von dir gewählten Kanal. Kein zusätzlicher App-Server ist erforderlich.

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

1. Eigenständige Swift-Regressionstests für Katalogformat, Beschädigung, Kontotrennung, Ordnerstruktur, Migration, Sendeabbruch, Wiederholung und Schreibfehler.
2. XcodeGen und die fest gepinnte TDLibFramework-Version.
3. Release-Build für iPhone und iPad ab iOS 17; Liquid Glass ab iOS 26.
4. Paket **`TGSpeicher-v3.0.0-unsigned.ipa`** als Actions-Artefakt.

Die IPA muss vor der Installation mit deiner Apple-ID beziehungsweise deinem Zertifikat signiert werden. Der Workflow verändert oder committet keinen App-Code mehr automatisch. Tests verwenden simulierte Telegram-Antworten; ein realer Telegram-/iCloud-/Neuinstallationsdurchlauf auf einem iPhone bleibt ein separater Gerätetest.

Technische Grundlagen: [TDLib-Sendeereignisse](https://core.telegram.org/tdlib/getting-started), [TDLib-Nachrichtensuche und Pagination](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1search_chat_messages.html), [Apple: synchronisierbare Schlüsselbund-Einträge](https://developer.apple.com/documentation/security/ksecattrsynchronizable).
