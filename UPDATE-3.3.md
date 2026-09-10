# TGSpeicher 3.3.0

## Update von 3.2

Die App-Bundle-ID bleibt `eu.simplexsmp.tgspeicher`. Katalogschema, Datei-IDs,
Playlist-IDs, Telegram-Nachrichten und bestehende Speicherpfade bleiben kompatibel.
Neue Kanal- und Audiofelder sind optional und können in alten Daten fehlen.
Ein Update verschiebt oder löscht keine vorhandenen Dateien.

Beim Sideloading dieselbe App-ID und Signieridentität wie bisher verwenden und die
vorhandene App aktualisieren. Die App vorher nicht löschen. Eine andere Signatur
oder ein anderes Team kann iOS als neue Installation behandeln; das lässt sich
nicht durch den App-Code verhindern.

## Musik

- Sichtbare Titel in Musiklisten, Playlists und Warteschlange laden Cover und Tags
  automatisch. Ein deduplizierter Worker begrenzt die Telegram-Last: ein Titel
  gleichzeitig, acht MiB Lese-Budget und fünfzehn Sekunden Zeitbudget pro Titel.
- Cover bleiben kontogetrennt auf dem Gerät gespeichert. iOS-dekodierbare Tags
  werden im vorhandenen Telegram-Katalog gesichert. Der manuelle Scan ist weiter
  verfügbar. Nicht lesbare Formate bleiben als Originaldateien erhalten.
- Der Reiter **Offline** zeigt vollständig heruntergeladene Musik. Ein langes
  Drücken auf einen Titel bietet Laden und Entfernen des lokalen Downloads.
  Download-Dateien werden nach Größe geprüft und atomar übernommen. Die Metadaten
  werden nach Wiederverbindung ergänzt; Audiodateien werden nicht unnötig erneut
  heruntergeladen. Offline-Wiedergabe ist mit vorhandener Telegram-Sitzung und
  lokalem Katalog auch möglich, wenn die Online-Wiederherstellung noch aussteht.
- Unter **Kanal** lässt sich optional ein beschreibbarer Telegram-Kanal auswählen
  oder ein privater Kanal erstellen. Neue Musik wird als `inputMessageAudio`
  einschließlich Titel und Künstler gesendet. Ungeeignete Formate und Dateien
  über dem Telegram-Limit werden verlustfrei als Dokument(e) gesichert.
- Ein Kanalwechsel gilt nur für neue Uploads. Bereits eingereihte Uploads behalten
  ihr Ziel, ältere Titel bleiben in der gesamten Musikbibliothek und in Playlists.
- Vorhandene Telegram-Audio-Nachrichten lassen sich seitenweise einpflegen.
  Nachrichten- und Datei-IDs verhindern doppelte Katalogeinträge. Das kopiert
  keine Audiodateien. Normale Dokumente aus fremden Apps müssen weiterhin über
  die Datei-/Katalogfunktionen eingepflegt werden.
- Der gewählte Kanal bekommt zusätzlich einen versionierten `.tgscatalog`-Index
  mit Musikreferenzen, Tags, Ordnerzuordnung und Playlists. Der bestehende
  Gesamtkatalog bleibt erhalten. Der Musikindex lässt sich im vorhandenen
  Wiederherstellungsbereich importieren.

## Übertragungen, Dynamic Island und Kurzbefehle

Die neue Widget-Erweiterung zeigt den laufenden Upload, Fortschritt, Geschwindigkeit,
wartende Uploads und den Stand einer gleichzeitig laufenden Fotosicherung. Es gibt
Layouts für Sperrbildschirm und alle Dynamic-Island-Darstellungen. Antippen öffnet
**Übertragungen**. Ein veralteter Status wird als solcher angezeigt.

Ab iOS 26 wird für ausdrücklich gestartete Uploads bzw. Fotosicherungen zusätzlich
`BGContinuedProcessingTask` angefordert. Automatisch wiederhergestellte Sicherungen
fordern diese Laufzeit nicht an. iOS entscheidet über Gewährung und Dauer. Bei
Ablauf/Abbruch pausiert die Warteschlange vor weiteren Dateien; bereits bestätigte
Nachrichten und der Upload-Journal bleiben zur Wiederaufnahme erhalten. Ältere
Systeme nutzen die vorhandene begrenzte Hintergrundlaufzeit.

Eine Live Activity ist eine Statusanzeige und hält die App nicht selbst am Leben.
Beim Sperren oder Wechsel in eine andere App befindet sich TGSpeicher im Hintergrund.
Nach erzwungenem Beenden im App-Umschalter können keine weiteren Uploads laufen.
Es gibt keine stumme Audio-Schleife, kein VoIP-Keepalive und keine private API.
Die vorhandene Audio-Hintergrundberechtigung dient ausschließlich echter Musik.

Die lokale Live Activity benötigt weder Push-Server noch App Groups. Der
Sideloading-Dienst muss die mitgelieferte `TGSpeicherLiveActivity.appex` mitsignieren
und einbetten; Dienste, die Erweiterungen entfernen, können die Anzeige nicht
bereitstellen. Bei fehlender Unterstützung funktionieren normale Uploads weiter.

Die Kurzbefehle-App erhält:

1. **Fotosicherung starten**, optional mit Nachtmodus.
2. **Datei-Eingang hochladen** aus `Upload Inbox`.
3. **Uploads fortsetzen** für die vorhandene Warteschlange.

Diese Aktionen öffnen TGSpeicher und warten auf eine bereitgestellte Sitzung und
den Katalog. Ein nicht binnen zwei Minuten ausführbarer Startauftrag verfällt.
Fotozugriff und das Sicherungsziel werden weiterhin in der App eingerichtet.

## Schutz vor Versehen

Abmelden verlangt exakt `ABMELDEN`. Beim lokalen Sitzungsreset und beim endgültigen
Datei-/Sammellöschen aus Telegram ist ein vollständiger Bestätigungssatz nötig.
Auch das Entfernen gesicherter Fotos/Videos vom iPhone verlangt einen Satz. Ohne
passende Eingabe bleibt der Ausführen-Knopf deaktiviert. Logout und Reset prüfen
zusätzlich im Telegram-Client selbst, ob die Bestätigung korrekt ist.

## Technische Prüfung

Der Prüfworkflow kompiliert die iOS-App samt Widget-Erweiterung und führt die
Recovery-/Queue-/Musik-Tests aus. Zusätzliche Upgrade-Tests prüfen alte JSON-Daten,
Kanalwechsel und Deaktivierung, persistente Upload-Ziele, Archiv-Wiederherstellung
und Bestätigungsphrasen. Der finale Workflow packt erst danach die unsignierte IPA
und prüft, dass die Live-Activity-Erweiterung enthalten ist.

Ein echter Sideload-, Sperrbildschirm-, Offline- und Telegram-Upload-Test ist
anschließend auf dem iPhone erforderlich; GitHub hat keinen Zugriff auf das Gerät.

## Apple-Referenzen

- [Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/)
- [Meet ActivityKit](https://developer.apple.com/videos/play/wwdc2023/10184/)
- [BGContinuedProcessingTaskRequest](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest)

- [Telegram inputMessageAudio](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1input_message_audio.html)
