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

Ein späterer CI-Lauf zeigte eine verpasste Änderung beim Austausch eines
überwachten Backup-Ordners. Nach dem Installieren neuer Verzeichniswachen
prüft das App-Modell deshalb einmal erneut. Damit erfasst es auch Dateien,
die zwischen Scan und Neuaufbau der Überwachung erstellt wurden. Die acht
gezielten App-Modell-Tests bestanden nach der Korrektur lokal.

Der Release-Build mit Xcode 27.0 und Swift 6.4 sowie die anschließende lokale
Ad-hoc-Signierung und Signaturprüfung bestanden ebenfalls. Für diesen Build-Check
wurde das Bundle nicht gestartet. Zwei unabhängige interne Reviews prüften Standards und
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
Die vier gezielten Kopier- und Parallelitätstests prüfen gesperrte Ziele,
vorhandene abgebrochene Kopien und den Erhalt anderer Zieldateien. Ein zweiter
interner Review prüfte die Korrektur. Er fand eine zeitabhängige Testprobe,
die entfernt wurde. Der Anforderungsreview fand keine weiteren Korrekturen.
Die Suite umfasst insgesamt 30 native Tests. Den späteren tatsächlichen
Prozessabbruch dokumentiert die folgende Prüfung der signierten App.

## Manuelle Nachweise und offene Prüfungen

### Signierte App mit künstlichen Daten am 1. Oktober 2026

Geprüft wurde der Release-Code von Commit `4e95282` auf macOS 27.0.1,
Build 26A434, Apple Silicon. Die QA-Kopie hatte die eigene Bundle-ID
`cloud.diesis.sync-copies.qa-20261001` und eigene Einstellungen. Nur Bundle-ID
und Anzeigename wurden geändert; die ausführbare Datei blieb unverändert.
Die Kopie wurde mit den ursprünglichen Sandbox-Entitlements ad-hoc signiert.
Der vorhandene Helfer und echte Strongbox-Dateien wurden nicht verwendet.

Computer Use bediente die echten macOS-Ordnerdialoge. Die Test-App erhielt
Lesezugriff auf die künstliche Quelle und Schreibzugriff auf einen Zielordner
in einem eigenen APFS-Diskimage. Im normalen App-Modell wurden zwei Datenbanken
aktiviert. Die dritte Metadaten-Zeile mit einem anderen Speicheranbieter erschien
nicht in der Auswahl. Beide Kopien waren bytegleich zur Quelle, hatten Modus
`0600` und wurden in der GUI als "Lokal kopiert" angezeigt.

Anschließend stürzte der native Computer-Use-Dienst wiederholt bei der Abfrage
der QA-App ab. Die Crashberichte zeigen einen Swift-Array-Indexfehler im Dienst.
Der Zugriff auf Finder funktionierte, der Zugriff auf die QA-App blieb auch nach
automatischer Wiederherstellung des Dienstes und Neustart der App blockiert.
Die Aufnahme beginnt nach den ersten Kopien und zeigt den Wechsel zu Allgemein.
Sie ist eine Teilaufnahme und dokumentiert weder die Ordnerfreigaben noch die
anschließenden Dateisystemtests.

Die folgenden Prüfungen liefen gegen dieselbe signierte App über künstliche
Dateiereignisse und Prozessstarts. Ergebnisse wurden anhand der Zielbytes und
der von der App gespeicherten Fehler- und Verlaufseinträge geprüft.

| Prüfung | Ergebnis |
| --- | --- |
| Neue Backups für beide Datenbanken | Ohne manuelles Prüfen automatisch kopiert. |
| Austausch eines überwachten Backup-Ordners | Neue Datei im Ersatzordner automatisch kopiert. |
| Zweiter Start derselben QA-App mit `open -n -W` | Zusätzlicher Start beendet sich sofort; die erste QA-PID bleibt bestehen. Die parallel offene ältere Vorschau hatte eine andere Bundle-ID. |
| Testvolume auswerfen und neue Quelle erzeugen | Beide Datenbanken melden ein unerreichbares Ziel. Das Volume wird nicht automatisch eingebunden. |
| Testvolume wieder einbinden | Alte Kopien unverändert erhalten. Nach einem neuen Quellereignis aktualisiert die App die Kopie und löscht den Fehlerzustand. |
| Neustart nach `SIGTERM` ohne aktive Kopie | Auswahl und Freigaben bleiben erhalten. Eine während der Pause erzeugte Quelle wird ohne neuen Ordnerdialog kopiert. |
| `SIGKILL` nach Erscheinen der temporären Datei einer 32-MiB-Kopie | Die vorherige Zieldatei bleibt erhalten. Die unvollständige temporäre Datei bleibt mit Modus `0600` liegen. |
| Wiederanlauf auf dem kleinen 64-MiB-Testvolume | Der erhaltene Testrest verursacht Platzmangel. Die App meldet den Fehler und erhält die alte Kopie. Nach manuellem Verschieben der Testreste aus dem Ziel funktioniert die Kopie wieder, mit identischen Bytes und zurückgesetztem Fehlerzustand. |

Die ursprünglichen künstlichen Backup-Dateien und Metadaten hatten am Ende
unveränderte SHA-256-Werte. Der Test selbst hatte einen Backup-Ordner umbenannt;
die darin liegende Originaldatei blieb ebenfalls unverändert.

Teilaufnahme und maschinenlesbare Ergebnisse liegen lokal unter
`macos-app/build/qa-evidence/issue-5-gui-teilaufnahme.mp4` und
`macos-app/build/qa-evidence/issue-5-results.json`. Sie werden nicht öffentlich
hochgeladen. Test-App, künstliche Quellen, Diskimage, beide Vorschau-Bundles und
übrige Testartefakte wurden nach der Prüfung entfernt. Beide laufenden App-Instanzen
wurden beendet. Eine erneute Prüfung mit NSWorkspace und der Prozessliste fand
keine weitere Instanz. Die Aufräumprüfung steht im Ergebnisprotokoll.

Der eigene Zielordner je Datenbank konnte über die GUI nicht mehr geprüft werden.
Ebenso fehlen Login mit tatsächlichem Ab- und Anmelden, physisches Schlafen und
Aufwachen, Entzug und erneute Erteilung einer OS-Freigabe sowie ein echtes NAS.
Das APFS-Diskimage belegt keine SMB-Sperrsemantik. `SIGTERM` ohne aktive Kopie und
`SIGKILL` während der Kopie belegen nicht das geordnete Beenden über das App-Menü.

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
- Die App während einer laufenden Kopie über ihr Menü beenden. Sie muss die Kopie
  abschließen und anschließend die Instanzsperre freigeben.
- Das Verhalten auf den unterstützten älteren macOS-Versionen prüfen.

Für jede manuelle Prüfung Datum, macOS-Version, Signierungsart und Ergebnis
ergänzen. Bis diese Nachweise vorliegen, bleibt Issue #5 für die manuellen
Abnahmeschritte offen. Der automatisierte Lauf ersetzt keine OS-Freigabeprüfung.
