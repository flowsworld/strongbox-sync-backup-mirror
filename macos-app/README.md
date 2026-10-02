# Sync-Kopien für macOS

Native Entwicklungsfassung der gewählten Oberfläche C1. Die App läuft in der
Menüleiste und hat getrennte Einstellungsseiten für Allgemein, Datenbanken,
Mitteilungen, Google Drive und Verlauf. Sie benötigt macOS 13 oder neuer.

## Verbindliche Produktvorgaben

Die App ist auf Deutsch und Englisch verfügbar. Sie folgt der macOS-App-Sprache
und fällt bei nicht unterstützten Sprachen auf Englisch zurück. Es gibt keinen
eigenen Sprachschalter. Datumsangaben, Dateigrößen und Anzahlen berücksichtigen
die gewählte Sprache und die regionalen Einstellungen. Neue Verlaufseinträge
speichern sprachneutrale Ereignisse. Bekannte alte Meldungen werden übersetzt;
sonstige alte Texte bleiben mit einem Hinweis auf ihre Originalsprache erhalten.
Als Namenskandidaten sind "Sync Backupdatei-Mirror (Strongbox)" und
"Strongbox Sync Backupdatei-Mirror" vorgesehen. Die Verwendung von "Strongbox"
ist vor dem endgültigen Namen zu klären. "Sync-Kopien" ist nur der bisherige
Entwicklungsname.

## Bauen und als Vorschau öffnen

```sh
zsh macos-app/build.zsh
open macos-app/build/Sync-Kopien.app --args --demo
```

Der Vorschaumodus zeigt Beispieldaten. Er kopiert keine Dateien, speichert keine
Einstellungen, fordert keine Ordner- oder Mitteilungsfreigabe an und registriert
kein Anmeldeobjekt. Die Datenbankauswahl und Ordneraktionen sind deaktiviert.
Die Mitteilungsauswahl lässt sich zur Ansicht ändern, bleibt aber nur im Speicher.

Das Build-Skript verwendet das installierte Xcode über `DEVELOPER_DIR`, ohne die
globale Entwicklerauswahl zu ändern. Es erstellt ein lokal ad-hoc signiertes
App-Bundle mit App Sandbox. Das ist noch kein Build für die Veröffentlichung.

## Reale Nutzung der Entwicklungsfassung

Ein Start ohne `--demo` verwendet eigene Einstellungen im Sandbox-Container der
App. Zuerst wird der Lesezugriff auf den bekannten Strongbox-Ordner über den
macOS-Ordnerdialog erteilt. Die Freigabe umfasst Metadaten und verschlüsselte
Backups. Die App entschlüsselt keine Datenbank und schreibt nicht in Strongbox.

Anschließend einen gemeinsamen Zielordner wählen und die gewünschten
Strongbox-Sync-Datenbanken aktivieren. Jede Aktivierung startet unmittelbar eine
Prüfung und kann eine bestehende gleichnamige Zieldatei ersetzen. Datenbanken
können eigene Zielordner erhalten. Mehrere aktive Datenbanken mit demselben
Zieldateinamen im selben Ordner werden blockiert.

Für einen ersten realen Test ausschließlich einen neuen, separaten Zielordner
verwenden. Der vorhandene Shell-Helfer und seine Konfiguration werden von der
App weder übernommen noch verändert. Beide sollten nicht dieselbe Zieldatei
aktualisieren.

Die App prüft alle 15 Minuten, bei überwachten Dateiänderungen und nach dem
Aufwachen, solange sie läuft. Der automatische Start beim Anmelden ist zunächst
ausgeschaltet und wird nur durch den Schalter in Allgemein registriert.

Fehler, erfolgreiche neue Kopien und behobene Kopierfehler können unabhängig
als Mitteilung ausgewählt werden. Fehler sind voreingestellt. macOS muss
Mitteilungen zusätzlich erlauben; dafür gibt es eine eigene Aktion und eine
Testmitteilung. Identische Fehler bleiben auch nach einem App-Neustart still.
Ereignisse ohne Mitteilungsfreigabe stehen im Verlauf und werden später nicht
als alte Meldungen nachgeliefert. Der Verlauf speichert höchstens 200 Ereignisse.

## Kopierverhalten

Der Adapter liest die internen Strongbox-Metadaten, filtert Strongbox Sync und
prüft die UUID-Zuordnung. Er wählt das neueste lokale `.bak` nach Erstellungszeit.
Ein leeres neuestes Backup führt zu einem Fehler; die App nimmt kein älteres.

Der Kopierkern prüft Dateien über Deskriptoren, lehnt Verknüpfungen ab und
vergleicht Quelle und Ziel. Unveränderte Inhalte werden nicht erneut geschrieben.
Geänderte Inhalte schreibt er mit Dateimodus `0600` in eine temporäre Datei im
Zielordner. Nach erneutem Prüfen der Quelle und des bisherigen Ziels ersetzt er
die Zieldatei mit einem atomaren Austausch. Die verdrängte Vorgängerdatei bleibt
unter `.synccopies-UUID.tmp` erhalten, auch nach erfolgreichem Kopieren. Eine
gleichzeitig geänderte Datei wird dadurch nicht gelöscht. Konflikte und
Dateisysteme ohne atomare Austauschoperation melden einen Fehler.
Abgebrochene Versuche können ebenfalls temporäre Dateien hinterlassen.
Diese Dateien belegen zusätzlichen Speicher. Verdrängte fremde Dateien behalten
ihre bisherigen Berechtigungen. Die App entfernt solche Dateien nicht automatisch.
Prüfe Inhalt und Herkunft vor einer manuellen Bereinigung; sie können neuere
Daten eines anderen Prozesses enthalten.
Die App speichert keine Passwörter und lädt keine Dateien in eine Cloud hoch.

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macos-app
```

Die Tests erzeugen künstliche Metadaten und Backups in temporären Verzeichnissen.
Sie prüfen den Kopierkern und das normale App-Modell mit isolierten Einstellungen.
Timer und Dateiüberwachung verwenden echte Auslöser; Aufwachen wird über eine
eigene NotificationCenter-Instanz simuliert. Ordnerfreigaben und Anmeldeobjekte
werden an der Betriebssystemgrenze ersetzt, damit die Tests keine persönlichen
Freigaben oder Login-Einstellungen verändern.
Sie lesen keine echte Strongbox-Datenbank und installieren kein Anmeldeobjekt.
Die GitHub-CI führt diese Swift-Tests zusätzlich zu den Tests des Shell-Helfers aus.

Der Nachweis für den normalen App-Lebenszyklus und seine Grenzen steht in
[docs/testing/issue-5-lifecycle.md](../docs/testing/issue-5-lifecycle.md).

## Lokalisierung prüfen

Die Sprachressourcen liegen in
`Sources/SyncCopiesCore/Resources/en.lproj` und `de.lproj`. Der Entwicklungsname
steht nur im Schlüssel `appName`; das Build-Skript erzeugt daraus auch die
lokalisierten Bundle-Anzeigenamen. Die Bundle-Kennung und die gespeicherten
Ordnerfreigaben bleiben beim Ändern des Anzeigenamens erhalten.

Für eine Vorschau mit ausschließlich prozesslokaler Sprachvorgabe:

```sh
open -n macos-app/build/Sync-Kopien.app --args --demo -AppleLanguages '(en)' -AppleLocale en_US
open -n macos-app/build/Sync-Kopien.app --args --demo -AppleLanguages '(de)' -AppleLocale de_AT
```

Ohne diese Testargumente folgt die App den Systemeinstellungen.
Prüfergebnisse und Grenzen stehen in
[docs/testing/issue-7-localization.md](../docs/testing/issue-7-localization.md).

## Isolierter Kopiertest

Der Diagnosemodus läuft in demselben signierten App-Bundle und derselben Sandbox
wie die Oberfläche. Er startet weder das normale App-Modell noch Timer,
Dateiüberwachung, Mitteilungen oder das Anmeldeobjekt. Seine Freigaben und Berichte
liegen getrennt von den normalen App-Einstellungen.

Zuerst den vollständig künstlichen Lauf starten:

```sh
open -n -W macos-app/build/Sync-Kopien.app --args --copy-test-fixtures
```

Für den Lauf mit echten, ausschließlich gelesenen Strongbox-Backups einen neuen
privaten Testordner anlegen und genau diesen über den zweiten Dialog freigeben:

```sh
copy_test_target="/private/tmp/strongbox-mirror-copy-test-$(uuidgen)"
mkdir -m 700 "$copy_test_target"
open -n -W macos-app/build/Sync-Kopien.app --args --copy-test --copy-test-target "$copy_test_target"
```

Die App verlangt zuerst eine eigene Lese-Freigabe für den Strongbox-Ordner und
danach eine Schreib-Freigabe für das exakt vorbereitete Testziel. Sie akzeptiert
keinen anderen Zielpfad. Jeder Lauf erzeugt darin einen neuen Unterordner mit
Zufallskennung; bestehende Testkopien werden nicht wiederverwendet. Quelldaten
werden im echten Lauf weder geändert noch entschlüsselt. Neuere und leere Backups
werden ausschließlich im künstlichen Lauf erzeugt.

Beide Läufe prüfen Datenbankzuordnung, Kopie und Inhaltsgleichheit, unveränderte
Dateien, eigene Ziele sowie das Überschreiben einer absichtlich geänderten
Testkopie. Der künstliche Lauf prüft zusätzlich neuere Backups, leere neueste
Backups und das Blockieren gleicher beziehungsweise unter Unicode kollidierender
Dateinamen. App und Testmodus verwenden dieselbe Zielprüfung.

Der Ergebnisbericht liegt unter
`~/Library/Containers/cloud.diesis.sync-copies/Data/Library/Application Support/SyncCopies/copy-test/latest-result.json`.
Er enthält nur Zeitstempel, Anzahl, feste Prüfnamen und Fehlercodes. Echte
Datenbanknamen, Kennungen, Pfade, Prüfsummen und verschlüsselte Inhalte stehen
nicht im Bericht. Die Testkopien selbst bleiben im privaten Testordner und können
mit dem temporären Ordner später vom System entfernt werden.

Der manuelle Diagnosemodus belegt den Kopierkern und den Sandbox-Zugriff. Der
normale Einstellungsablauf, automatische Auslöser, Login, Wake und Mitteilungen
benötigen weiterhin eigene Integrationstests. `open` allein meldet nicht das
Testergebnis; entscheidend sind Modus, aktueller Zeitstempel und `failed: 0`
im Bericht.

## Noch offen vor Veröffentlichung

Die Vorbereitung für Google Drive, Release-Bau und Updates ist dokumentiert:

- [Native Google-Drive-Prüfung](../docs/research/native-google-drive-verification.md),
  mit einem getesteten providerneutralen Prüfkern. OAuth, Drive-Adapter und
  App-Integration sind noch nicht enthalten.
- [Release-Vorbereitung](../docs/research/macos-release-preparation.md),
  mit `zsh macos-app/release.zsh development VERSION BUILD` für einen isolierten
  Universal-Kandidaten. Ein Ad-hoc-Build ist keine signierte Beta.
- [Store- und Direkt-Updates](../docs/research/macos-update-distribution.md),
  mit Sparkle-Recherche und den noch offenen signierten Integrationstests.
- [Oberflächenvarianten für die offenen Aufgaben](https://pages.diesis.cloud/d/sm01ct3cwj0o).
  Ihre Auswahl steht vor Änderungen an der echten Oberfläche.

Die optionale Google-Drive-Prüfung folgt in einem Update. Diese Fassung bestätigt
nur die lokale Kopie. Flos vollständiger Umstieg wartet auf die Google-Drive-Prüfung.

Produktionssignierung und App-Store-Paket, App-Store-Prüfung, Login und Wake im
Dauerbetrieb, entzogene Ordnerfreigaben, macOS-Versionsabdeckung und Tests mit
NAS- beziehungsweise Cloud-Zielmedien sind noch ausständig. Die erfolgreiche Sandbox-Probe unter
[experiments/macos-sandbox-probe](../experiments/macos-sandbox-probe/README.md)
belegt den Lesezugriff des separaten Experiments, nicht all diese Eigenschaften
der fertigen App. Die privaten Strongbox-Metadaten bleiben eine zu wartende
Abhängigkeit.

## Prüfung dieser Entwicklungsfassung

Zwei unabhängige Reviews prüften Verhalten und Dateisicherheit. Alle sechs
Befunde wurden verifiziert und behoben, anschließend wurden die Korrekturen
gezielt nachgeprüft. Es gab keine verworfenen Befunde.

- Verzeichniszugriffe verwenden für übergeordnete Ordner Suchzugriff statt
  Lesezugriff. Nur das freigegebene Zielverzeichnis wird zum Lesen geöffnet.
- Die Kollisionsprüfung berücksichtigt Unicode-Fallgleichheit und die physische
  Identität des Zielordners. Ein zusätzlicher Test deckt die gefundenen Paare ab.
- Menü- und Mitteilungsklicks öffnen die Datenbankdetails auch beim ersten
  Öffnen des Fensters und nach erneutem Zuklappen.
- Dateiänderungen erzwingen ein neues Öffnen der Überwachung, damit ein
  ersetzter Ordner unter demselben Pfad weiterhin überwacht wird.
- Erholter Strongbox-Lesezugriff erscheint im Verlauf und kann eine ausgewählte
  Meldung für behobene Fehler auslösen.
- Vorübergehende Schreibfehler der Einstellungen werden beim nächsten Prüflauf
  erneut versucht. Ein Fehler beim erstmaligen Lesen bleibt geschützt.

Der Zugriff mit Suchrechten wurde zusätzlich mit einer isolierten synthetischen
Seatbelt-Regel geprüft. Der neue Kopierkern besteht inzwischen auch den unten
beschriebenen App-Sandbox-Test mit echter Lese-Freigabe und einem separaten
Schreibziel. Integrationsprüfungen des normalen Einstellungsablaufs, von
Mitteilungen und Dateiüberwachung stehen noch aus. Die Oberfläche wurde von
Flo manuell angesehen; eine visuelle Prüfung wurde nicht automatisiert.

## Ergebnis des Kopiertests vom 1. Oktober 2026

Getestet auf dem bisherigen Entwicklungs-Mac mit lokal ad-hoc signiertem
App-Bundle und aktivem App Sandbox. Die tatsächlichen Quelldaten wurden nur
mit der vom Benutzer bestätigten Lese-Freigabe gelesen. Das Schreibziel war ein
neu angelegter privater Ordner unter `/private/tmp`, mit eigener bestätigter
Schreib-Freigabe und ohne Cloud-Synchronisation.

| Lauf | Ergebnis | Aussage |
| --- | --- | --- |
| Swift Testing | 12 Tests bestanden | Kopierkern, Katalog und gemeinsame Zielprüfung |
| Sandboxed künstlicher Lauf | 19 Prüfungen bestanden, 2 Testdatenbanken | Neue und leere Backups, eigene Ziele, unveränderte Inhalte, Wiederherstellen von Testkopien sowie gleiche und Unicode-kollidierende Dateinamen |
| Sandboxed echter Lauf | 13 Prüfungen bestanden, 2 Strongbox-Sync-Datenbanken | Neueste verschlüsselte Backups lesen, gemeinsame Ziele, Inhaltsgleichheit, unveränderte Dateien, eigene Ziele und Wiederherstellen einer absichtlich veränderten Testkopie |
| Frischer App-Prozess | Erneut 13 Prüfungen bestanden | Beide gespeicherten Freigaben funktionieren ohne erneuten Dialog |

Die Testdateien hatten Modus `0600`, ihre Verzeichnisse `0700`. Die Quellen,
vorhandenen Helfer-Konfigurationen, LaunchAgents und bisherigen Zieldateien
wurden nicht verändert. Die Tests entschlüsselten keine Datenbank und luden
nichts hoch. Die privaten temporären Kopien bleiben zur Nachprüfung erhalten.

Zwei unabhängige Reviews fanden zwei Lücken im Diagnosemodus: eine fehlende
Anzahlprüfung vor der Kollisionsprüfung und das vorzeitige Scheitern bei einer
unbrauchbaren Freigabe für einen früheren Testordner. Beide Befunde wurden
verifiziert, behoben und gezielt nachgeprüft. Keine Befunde wurden verworfen.
Der erste echte Lauf stoppte außerdem vor dem Kopieren, weil Foundation den
vorbereiteten Pfad `/private/tmp` zu `/tmp` normalisiert. Der Testmodus vergleicht
nun die physische Verzeichnisauflösung und verwendet den ausdrücklich
vorbereiteten physischen Pfad. Die Pfadkorrektur wurde gezielt geprüft.

Die Ergebnisse belegen den Kopierkern, den gemeinsamen Zielplaner und den
Sandbox-Zugriff des App-Bundles. Sie belegen noch keinen automatischen Lauf
über das normale App-Modell. Neue Quelldateien wurden nur künstlich erzeugt;
echte Strongbox-Backups wurden ausschließlich gelesen. NAS, Cloud-Prüfung,
Mitteilungen, Dateiüberwachung, Anmeldung und Wake sind nicht Teil dieses Laufs.
Die gezählten Berichte liegen im ignorierten Build-Verzeichnis, ohne echte
Datenbanknamen, Kennungen, Quellpfade, Prüfsummen oder Inhalte.

## Mitteilungen geprüft am 2. Oktober 2026

Die Zustellung wurde mit einem eigenen signierten Sandbox-App-Bundle und
künstlichen Dateien geprüft. Verweigerte und später geänderte Mitteilungsfreigaben,
getrennte Kategorien, Fehlerwiederholungen über Neustarts, beide Erholungsarten
und echte Mitteilungsklicks auf Datenbankdetails bestanden die Prüfung.
Eine während der macOS-Abfrage ausgeschaltete Kategorie verhindert jetzt auch
die bereits begonnene Zustellung. Noch ausstehende macOS-Anfragen dieser Kategorie
werden entfernt; frühere Ereignisse werden nach einem Neustart nicht nachgeliefert.

Die 8 neuen Mitteilungstests prüfen 16 Fälle ohne macOS-Freigabedialoge. Der
vollständige native Testlauf besteht aus 69 Testfunktionen. Ergebnisse, Aufbau
und Grenzen der nativen Prüfung stehen in
[issue-6-notifications.md](../docs/testing/issue-6-notifications.md).
