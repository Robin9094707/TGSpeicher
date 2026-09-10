# TGSpeicher 3.3.2 (Build 35)

Stabilitätskorrekturen für Einfrieren bei Musik, Tabwechseln und kurzer App-Nutzung.

- Der Root hält alle abhängigen Manager in einem einmalig erzeugten StateObject.
  UI-Updates erzeugen keine zusätzlichen Upload-Queues und Foto-Manager mehr und
  wiederholen deren Wiederherstellung, lokale Schreibvorgänge und Exportbereinigung nicht.
- Die Wiedergabezeit hat ein eigenes ObservableObject. Nur Fortschrittsanzeige und
  Suchregler beobachten es; die Musikbibliothek und Tabs werden nicht pro Tick neu aufgebaut.
- Der Audiolader empfängt TDLib-Antworten direkt auf seiner seriellen Hintergrund-Queue.
  Seine Datenversorgung hängt nicht mehr vom Hauptthread ab. Während ein Titel noch
  vorbereitet wird, fragt der Timer keine synchrone Dauer ab.
- Audio- und Metadatenanfragen haben ein Zeitlimit. Antwort, Timeout und Sitzungsende
  schließen einen Callback höchstens einmal ab und geben den registrierten Callback frei.
- Telegram veröffentlicht den Aktivitätszeitstempel höchstens einmal pro Sekunde;
  einzelne Audioblock-Anfragen erzeugen keine dauernden Debug-UI-Aktualisierungen.
- Erneute Offline-Scans brechen den vorherigen Dateisystem-Scan ab. Veraltete Ergebnisse
  überschreiben keine zwischenzeitlich hinzugefügten oder entfernten Offline-Downloads.

Validierung: Der IPA-Workflow parst alle Swift-Dateien, führt die vorhandenen
Wiederherstellungs-/Uploadtests und neue Callback-Tests aus und kompiliert App und
Live-Activity-Erweiterung. Die Callback-Tests prüfen u. a. einen blockierten Hauptthread,
Timeouts, Sitzungsende und konkurrierende Antworten. Die Gerätesymptome müssen nach
Installation mit Musik, schnellen Tabwechseln und Hintergrundwechsel geprüft werden;
ein Crashbericht des betroffenen Geräts lag bei dieser Korrektur nicht vor.
