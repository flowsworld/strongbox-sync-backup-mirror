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

Der Release-Build mit Xcode 27.0 und Swift 6.4 sowie die anschließende lokale
Ad-hoc-Signierung und Signaturprüfung bestanden ebenfalls. Das Bundle wurde
nicht gestartet. Zwei unabhängige interne Reviews prüften Standards und
Issue-Anforderungen. Beide fanden keine weiteren Korrekturen. Die fehlenden
manuellen Abnahmeschritte wurden im Anforderungsreview ausdrücklich bestätigt.

Für die Bereinigung muss eine temporäre Datei den reservierten UUID-Dateinamen,
Modus `0600`, den aktuellen Besitzer, genau einen Hardlink und die eigene
erweiterte Dateimarkierung der App besitzen. Fertige Kopien tragen diese Markierung
nicht. Eine gleich benannte Datei ohne Markierung bleibt erhalten. Unterstützt
das Dateisystem keine erweiterten Attribute, kopiert die App weiterhin, lässt
aber abgebrochene temporäre Dateien liegen. Auch ein Abbruch zwischen dem
Entfernen der Markierung und dem atomaren Ersetzen kann eine solche Datei
hinterlassen. Die Bereinigung entfernt sie vorsichtshalber nicht.

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
