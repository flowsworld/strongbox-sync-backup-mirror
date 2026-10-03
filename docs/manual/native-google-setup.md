# Google-Anmeldung für die native App vorbereiten

Die native App benötigt ein eigenes Google-Cloud-Projekt mit einem OAuth-Client
vom Typ **Desktop app**. Verwende das Projekt des bisherigen Helfers nicht.
Der native Keychain-Dienst ist ebenfalls getrennt. Bestehende Helfer-Tokens
werden weder gelesen noch migriert.

## Schritte in Google Cloud

1. Ein getrenntes Entwicklungsprojekt anlegen und die Google Drive API aktivieren.
2. Unter Google Auth Platform das Branding einrichten. Audience zunächst
   External/Testing wählen und die vorgesehenen Testkonten hinzufügen.
3. Genau `https://www.googleapis.com/auth/drive.metadata.readonly` eintragen.
   Das Recht gilt für Metadaten aller Drive-Dateien. Die spätere Ordnerwahl
   begrenzt die Abfragen der App, nicht die OAuth-Berechtigung.
4. Einen Desktop-Client erstellen. Die App verwendet PKCE und einen kurzlebigen
   Callback auf `127.0.0.1` mit zufälligem Port. Keinen Web-Client verwenden.
5. Projekt-ID, Client-ID und optionales Desktop-Client-Secret lokal speichern.
   Die Client-Konfiguration ist kein Nutzer-Refresh-Token. Keine privaten
   Schlüssel, Nutzer-Tokens oder Passwörter in Issues oder Git speichern.

Ein vorbereiteter lokaler Wizard führt durch diese Schritte und speichert die
Werte mit Modus `0600` außerhalb des Repositorys. Er wurde syntaktisch und mit
ShellCheck geprüft, aber nicht ausgeführt. Er legt selbst kein Projekt an.

Standarddatei des Wizards:

```text
~/.config/diesis/native-google-drive/client.env
```

Bei gesetztem `XDG_CONFIG_HOME` liegt sie dort unter
`diesis/native-google-drive/client.env`. `NATIVE_GOOGLE_CONFIG_FILE` kann vor dem
Wizard-Aufruf einen anderen Pfad wählen. Die Datei enthält ausschließlich:

```text
GOOGLE_DRIVE_NATIVE_PROJECT_ID=dein-projekt
GOOGLE_DRIVE_NATIVE_CLIENT_ID=dein-desktop-client.apps.googleusercontent.com
GOOGLE_DRIVE_NATIVE_CLIENT_SECRET=optionales-desktop-client-secret
```

## Einen isolierten Kandidaten konfigurieren

Die Datei wird ausdrücklich als Daten eingelesen, niemals mit `source` ausgeführt.
Ein Build ohne diese Option enthält keinen Google-Client und startet keine Anmeldung.

```sh
/bin/zsh macos-app/build.zsh --google-client-config \
  "$HOME/.config/diesis/native-google-drive/client.env" \
  --output /tmp/Native-Drive-Test.app
```

Für `release.zsh` kann derselbe absolute Pfad mit
`DIESIS_GOOGLE_CLIENT_CONFIG` angegeben werden. Die Client-Werte werden vor dem
Signieren in das Kandidaten-Bundle geschrieben. Nutzer-Zugangsdaten bleiben im
getrennten Data-Protection-Keychain-Dienst der App.

## Noch zu prüfen

Ein echtes Google-Projekt und eine gültig signierte App mit passender
Keychain-Berechtigung fehlen auf diesem Mac. Ein ad-hoc signierter Kandidat
belegt keinen funktionierenden geschützten Keychain-Zugriff. Nach Einrichtung
müssen Browser-Anmeldung, Abbruch, Ablauf, Refresh nach Neustart, zwei Konten,
Ordnerrechte und lokale Trennung mit synthetischen Dateien geprüft werden.
Kein Test darf Strongbox-Originale oder bestehende Helfer-Zugangsdaten verändern.

External/Testing-Refresh-Tokens können nach sieben Tagen ablaufen. Der
Metadaten-Scope ist eingeschränkt. Öffentliche Verteilung und Googles
Verifizierung brauchen eine gesonderte Vorbereitung einschließlich Datenschutz.
Die Quellen und die ausführliche Testmatrix stehen in
[der OAuth-Recherche](../research/native-google-drive-verification.md).
