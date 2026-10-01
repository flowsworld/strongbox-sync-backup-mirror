# Automatische Kopien und App-Lebenszyklus

Diese Prüfung gehört zu [Issue #5](https://github.com/flowsworld/strongbox-sync-backup-mirror/issues/5).
Sie verwendet künstliche Strongbox-Metadaten und Backup-Inhalte, eigene temporäre
Zielordner und eine separate Einstellungsdatei je Test. Der vorhandene Helfer,
sein LaunchAgent, echte Strongbox-Dateien und tägliche Zielordner bleiben unberührt.

## Automatisierte Prüfung

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macos-app
```

Die App-Tests importieren das normale App-Modell. Katalog, Zielplanung und
Kopierkern laufen unverändert. Der Test ersetzt nur Ordnerfreigaben, Mitteilungen
und den Login-Dienst an der Betriebssystemgrenze. Er erteilt keine Freigaben und
registriert kein Anmeldeobjekt. Timer laufen mit kürzerem Intervall. Dateiänderungen
finden auf dem Dateisystem statt; Wake verwendet eine isolierte NotificationCenter-
Instanz mit derselben macOS-Nachricht wie im normalen Betrieb.

Die Instanzsperre liegt im privaten Einstellungsordner und bleibt als Datei liegen.
Das offene Dateihandle hält die Sperre. Ein weiterer Prozess darf weder laden
noch kopieren. Beim Beenden stoppt die App ihre Auslöser, wartet auf die laufende
Kopie und gibt anschließend die Sperre frei.

Der Kopierkern sperrt den Zielordner über ein unabhängiges Dateihandle. Bei
belegtem Ziel meldet er einen Fehler und versucht es beim nächsten Prüflauf
erneut. Unterstützt ein Zielmedium die Sperre nicht, bricht die App vor dem
Ersetzen ab. Diese Tests belegen das Verhalten auf dem lokalen Dateisystem,
nicht die Sperrsemantik eines beliebigen NAS.

Am 1. Oktober 2026 bestanden auf macOS 27.0.1, Build 26A434, Apple Silicon
alle 30 nativen Tests. Davon prüfen acht das App-Modell, sechs Laufzeitdienste
und 16 den Katalog, Zielplaner und Kopierkern. Zusätzlich bestanden alle 107
Python-Tests des bestehenden Helfers. Die nativen Tests liefen als
Entwicklungs-Testprozess, ohne Signierung als Sandbox-App. Die Sandbox-Freigaben
sind durch diesen Lauf nicht erneut belegt.

Die CI für Commit `d963b11` bestand anschließend auch auf macOS 15.7.9,
Build 24G830, mit Xcode 16.4. Alle 30 nativen Tests und beide Python-Jobs
bestanden. Für dieses ältere SDK wurden die Benachrichtigungszugriffe auf
Callback-APIs umgestellt. Nur Statuswerte und Ergebnisse wechseln den Actor;
SDK-Referenzobjekte bleiben am Aufrufort.

Der Release-Build mit Xcode 27.0 und Swift 6.4 sowie die anschließende lokale
Ad-hoc-Signierung und Signaturprüfung bestanden ebenfalls. Das Bundle wurde
nicht gestartet. Zwei unabhängige interne Reviews prüften Standards und
Issue-Anforderungen. Beide fanden keine weiteren Korrekturen. Die fehlenden
manuellen Abnahmeschritte wurden im Anforderungsreview ausdrücklich bestätigt.

Die App löscht keine temporären Dateien automatisch. Eine abgebrochene Kopie
kann eine Datei mit Namen `.synccopies-<UUID>.tmp` und Modus `0600` im Zielordner
hinterlassen. Sie enthält ausschließlich die künstlichen beziehungsweise
verschlüsselten Backup-Bytes, die bereits für diese Kopie gelesen wurden.
Ein erfolgreicher atomarer Austausch verbraucht die aktuelle temporäre Datei.
Verbliebene Dateien können im eigenen Zielordner manuell entfernt werden.

Der einmalige externe Codex-Review von Commit `d963b11` fand ein Rennen zwischen
Eigentumsprüfung und Löschen. Ein Sync-Client muss die App-Sperre nicht beachten
und kann den geprüften Dateipfad zwischen beiden Schritten ersetzen. Die
Korrektur entfernt automatische Bereinigung und das Löschen im Fehlerpfad.
Dadurch entfällt diese Möglichkeit, eine fremde Datei versehentlich zu löschen.
Der Review wird gemäß der vereinbarten Einmal-Regel nicht erneut angefordert.
Die fünf gezielten Kopier- und Parallelitätstests der Korrektur bestanden lokal.
Ein zusätzlicher Test ändert eine künstliche Quelle nach dem Erstellen der
temporären Datei. Die Kopie muss mit Fehler abbrechen, das bisherige Ziel
erhalten und die temporären Backup-Bytes mit Modus `0600` liegen lassen.
Die Suite umfasst damit insgesamt 31 native Tests.

## Manuelle Nachweise und offene Prüfungen

Der frühere manuelle Kopiertest mit Lese-Freigabe und separatem Schreibziel ist
im [App-README](../../macos-app/README.md#ergebnis-des-kopiertests-vom-1-oktober-2026)
dokumentiert. Dieser Test belegt den Sandbox-Zugriff des Diagnosemodus. Er ist
kein Nachweis für Login, automatisches Kopieren oder physisches Aufwachen.

Noch separat an einem signierten App-Bundle mit ausschließlich eigenen Testzielen
prüfen:

- Login einschalten, abmelden und wieder anmelden. Die App muss einmal starten
  und die gespeicherte Auswahl verwenden. Danach Login ausschalten und erneut
  anmelden. Die App darf nicht automatisch starten.
- Den Mac tatsächlich schlafen lassen und aufwecken. Eine zwischenzeitlich
  geänderte Testquelle muss nach dem Aufwachen aktualisiert werden.
- Source- und Ziel-Freigaben auf Betriebssystemebene entziehen beziehungsweise
  veralten lassen. Fehler müssen sichtbar bleiben und vorhandene Kopien erhalten.
  Nach erneuter Freigabe muss die App wieder kopieren.
- Ein separates NAS-Testziel trennen und wieder verbinden. Vorhandene Kopien
  dürfen während des Fehlers nicht ersetzt werden. Sperren und atomarer Austausch
  müssen auf diesem Zielmedium funktionieren.
- Eine laufende Kopie in einem eigenen Testziel durch Prozessabbruch unterbrechen
  und erneut starten. Zusätzlich zwei tatsächlich getrennte App-Prozesse starten.
- Das Verhalten auf den unterstützten älteren macOS-Versionen prüfen.

Für jede manuelle Prüfung Datum, macOS-Version, Signierungsart und Ergebnis
ergänzen. Bis diese Nachweise vorliegen, bleibt Issue #5 für die manuellen
Abnahmeschritte offen. Der automatisierte Lauf ersetzt keine OS-Freigabeprüfung.
