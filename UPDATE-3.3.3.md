# TGSpeicher 3.3.3 (Build 36)

- Dateiauswahl: sichtbare Aktionsleiste oberhalb der Liste bzw. des Rasters mit
  „Alle“, „Bewegen“, „Tags“ und „Löschen“. Der Mini-Player verdeckt diese Aktionen nicht.
- Normales Löschen von Dateien (einzeln oder mehrfach) und leeren Ordnern nutzt
  einen Ja/Nein-Dialog. Abmelden, Zurücksetzen und das Löschen gesicherter Medien
  aus der iPhone-Fotomediathek behalten ihre stärkeren Bestätigungen.
- Das X am Mini-Player stoppt die Wiedergabe, beendet den Audiolader, entfernt die
  Warteschlange und Sperrbildschirm-Anzeige und löscht die gespeicherte Player-Sitzung.
  Ein bereits laufender Offline-Download darf fertig werden.
- Importierte Kanal-Musik liegt in einer eigenen Sammlung im Musikkatalog und
  erscheint nicht mehr unter „Meine Dateien“. Alte externe Importe werden anhand
  der exakten früheren Import-Kennung übernommen. Eigene Uploads im selben Kanal
  bleiben eigene Dateien; Musik-IDs, Playlists und Offline-Pfade bleiben erhalten.
- Kanalreferenzen können einzeln oder im Kanalbereich mehrfach aus der Mediathek
  entfernt werden. Dabei wird keine Nachricht im externen Kanal gelöscht.
  Entfernungseinträge verhindern, dass alte Kataloge entfernte Referenzen zurückbringen.
- Neue Regressionstests prüfen Abwärtskompatibilität, wiederholte Migration,
  Katalog-Roundtrip, Playlist-Erhalt und Schutz vor Wiedererscheinen alter Importe.

Der IPA-Workflow führt Syntaxprüfung, Wiederherstellungs-/Musiktests,
Callback-Tests und den vollständigen Xcode-Build aus. Die Bedienung auf dem iPhone
ist nach Installation in Liste und Raster sowie mit offenem Mini-Player zu prüfen.
