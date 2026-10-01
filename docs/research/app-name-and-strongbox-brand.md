# App-Name und Verwendung von Strongbox

Stand: 1. Oktober 2026. Entscheidungsgrundlage für [Issue #8](https://github.com/flowsworld/strongbox-sync-backup-mirror/issues/8). Der endgültige Name ist offen und wird von Flo gewählt. Diese Recherche ändert keine Produkttexte und erteilt keine Markenfreigabe.

## Produkt und Ergebnis

Die native macOS-App kopiert das neueste lokale, verschlüsselte Backup einer Strongbox-Sync-Datenbank in einen gewählten Zielordner. Sie entschlüsselt keine Datenbank, schreibt nicht zurück in Strongbox und lädt selbst nichts hoch. Die Kopie ersetzt bei Änderungen dieselbe Zieldatei; sie ist kein eigener Versionsverlauf. Das kommerzielle Ziel ist ein Einmalkauf um EUR 5. Grundlage sind die [Produktvorgaben im Commit 699ff21](https://github.com/flowsworld/strongbox-sync-backup-mirror/blob/699ff21a4283e415ec5d7a4cc223581bd7fe506e/macos-app/README.md), nicht nur der bisher veröffentlichte Shell-Helfer.

In den unten geprüften Strongbox-Quellen fand sich keine ausdrückliche Freigabe, den Namen für eine kostenpflichtige Drittanbieter-App zu verwenden. Eine fehlende veröffentlichte Regel ist weder Erlaubnis noch Verbot. Ein eigener Name mit einer sachlichen Kompatibilitätsbeschreibung erscheint als sinnvoller Vorschlag. Auch diese Beschreibung braucht die noch offene Rechteklärung; sie garantiert keine Store-Zulassung.

## Was Strongbox ausdrücklich veröffentlicht

| Quelle | Aussage und Grenze |
| --- | --- |
| [Terms of Use](https://strongboxsafe.com/terms/) | Website-Inhalte einschließlich Logos gehören Phoebe Code Limited beziehungsweise den Urhebern. Die gewährte Website-Nutzung ist persönlich und begrenzt. Daraus folgt keine Lizenz für App-Namen, Logos oder Store-Material eines kommerziellen Drittanbieters. |
| [About](https://strongboxsafe.com/about/) | Nennt Phoebe Code Limited als Eigentümer und `info@phoebecode.com` ausdrücklich für Geschäftskorrespondenz. Die [Übernahmeankündigung vom 13. März 2025](https://strongboxsafe.com/strongbox-joins-applause/) nennt hingegen Applause als neue Verantwortliche. Wer heute die konkrete Erlaubnis erteilen darf, muss die Antwort bestätigen. |
| [Quellcode und README](https://github.com/strongbox-password-safe/Strongbox), [LICENSE.md](https://github.com/strongbox-password-safe/Strongbox/blob/master/LICENSE.md) | Der veröffentlichte Code trägt AGPL v3. Das README bezeichnet den unvollständigen Build seit Dezember 2024 als nicht OSI-konform und nennt fehlende Grafiken und Build-Dateien. Die Code-Lizenz ist keine ausdrückliche Strongbox-Markenlizenz. Abschnitt 7 erlaubt unter anderem zusätzliche Bedingungen zu Namen und Marken; das ist keine konkret ausgesprochene Markenfreigabe oder separate Markenverbotsklausel. |
| [Backup-Hilfe](https://strongbox.reamaze.com/kb/faqs/does-strongbox-store-backups-how-can-i-export-them), [macOS-Backup-Ort](https://strongbox.reamaze.com/kb/security-and-privacy/where-are-strongbox-local-backups-stored-on-my-mac) | Strongbox beschreibt lokale Backups als Kopien der verschlüsselten Datenbank und dokumentiert ihren macOS-Ort. Die allgemeine Backup-Hilfe warnt, dass die Orte sich ändern können. Das dokumentiert Dateizugriff, aber keinen stabilen Integrationsvertrag und keine kommerzielle Namenslizenz. |

Geprüft wurden die offizielle Website, About, Terms, Support, die genannten Knowledge-Base-Artikel sowie das verlinkte Quellcode-Repository mit README und Lizenz. Eine gesonderte öffentlich verlinkte Richtlinie für Drittanbieter-Namen oder ein Partnerprogramm wurde dabei nicht gefunden. Das ist keine vollständige Markenregister- oder rechtliche Prüfung. Strongbox-Logo, Icons und Website-Texte sind daher keine freigegebenen Gestaltungsressourcen.

## Vertrieb und Store-Namen

Apple verlangt in 2.3.7 einen eindeutigen App-Namen mit höchstens 30 Zeichen. Fremde Marken dürfen nicht zur Suchmanipulation dienen; Untertitel dürfen keine anderen Apps nennen. Preise gehören nicht in diese Namensmetadaten. 5.2.1 verlangt Erlaubnis für geschütztes Fremdmaterial und untersagt irreführende Namen. 5.2.2 verlangt bei Drittanbieter-Diensten zulässigen Zugriff und auf Nachfrage Nachweise. Ob das lokale Backup-Werkzeug darunter fällt, ist nicht vorentschieden. [App Review Guidelines, 2.3.7 und 5.2](https://developer.apple.com/app-store/review/guidelines/)

Für den Mac App Store verlangt 2.4.5 Sandbox, ein eigenständiges Xcode-Paket, Zustimmung zum Autostart, Store-Updates und alle Sprachen in einem Bundle. 2.5.1 verlangt öffentliche APIs. 4.2.3 verlangt Funktion ohne Installation einer anderen App. Die Strongbox-Abhängigkeit und der Zugriff auf dessen lokale Dateien müssen deshalb im Review erklärt werden. Die Sandbox-Probe allein belegt keine Zulassung. [App Review Guidelines, 2.4.5, 2.5.1 und 4.2.3](https://developer.apple.com/app-store/review/guidelines/)

Für regulären Direktvertrieb mit Gatekeeper verlangt Apples Notarisierungsablauf gültige Developer-ID-Signaturen, Hardened Runtime und sicheren Zeitstempel. Notarisierung prüft unter anderem Schadsoftware und Signierung; sie ist kein App Review und keine Markenfreigabe. Das vorhandene ad-hoc signierte Entwicklungsbundle erfüllt diesen Veröffentlichungsweg noch nicht. [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [aktuelles Build-Skript](https://github.com/flowsworld/strongbox-sync-backup-mirror/blob/699ff21a4283e415ec5d7a4cc223581bd7fe506e/macos-app/build.zsh)

Store-Name und Untertitel sind lokalisierbar und auf je 30 Zeichen begrenzt. Die Kompatibilität mit Strongbox gehört deshalb, vorbehaltlich der Freigabe, in die Beschreibung und Review-Notizen, nicht als Untertitel-Ausweichlösung. Verfügbarkeit und Rechte der unten genannten eigenen Namen sind noch ungeprüft. [App Store Connect: App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

## Kandidaten für Flos Auswahl

Die Zeichenanzahlen enthalten Leerzeichen und Satzzeichen. Alle Vorschläge bezeichnen eine Kopie. Keiner verspricht bidirektionale Synchronisation. Die funktionale Erklärung bleibt erforderlich, insbesondere die Beschränkung auf das neueste Backup.

| Deutsch | Englisch | Zeichen DE / EN | Einordnung |
| --- | --- | --- | --- |
| DIESIS Backup-Kopie | DIESIS Backup Copy | 19 / 18 | Eigener Absender im Namen; beschreibt die Funktion, ohne Strongbox als Hersteller erscheinen zu lassen. |
| Backupdatei-Kopie | Backup File Copy | 17 / 16 | Direkte Funktionsbeschreibung; als allgemeiner Name weniger unterscheidbar. |
| Datenbank-Kopie | Database Copy | 15 / 13 | Kurz; braucht die Erklärung, dass die Quelle ein verschlüsseltes Backup ist. |
| Backup-Kopie für Strongbox | Backup Copy for Strongbox | 26 / 25 | Beschreibt den Zweck als Drittanbieter-Helfer. Nur als bedingter Kandidat nach ausdrücklicher Freigabe und eigener Store-Prüfung. |

Flos bisherige Vorschläge haben 35 Zeichen bei "Sync Backupdatei-Mirror (Strongbox)" und 33 bei "Strongbox Sync Backupdatei-Mirror". Beide überschreiten das Store-Limit. "Strongbox" am Anfang kann Herstellerzugehörigkeit nahelegen. "Sync" und "Mirror" lassen außerdem offen, ob die App Dateien zurückschreibt. Das sind Gründe für die kürzeren Kopie-Kandidaten, keine bereits getroffene Namensentscheidung.

Als Erklärungstext zur späteren Prüfung, noch nicht als angewandte Produktkopie:

- DE: "Kopiert das neueste lokale, verschlüsselte Backup deiner Strongbox-Sync-Datenbank in einen gewählten Ordner. Eine vorhandene Kopie wird aktualisiert. Unabhängig von Strongbox entwickelt; keine Synchronisation zurück zu Strongbox."
- EN: "Copies the latest local encrypted backup of your Strongbox Sync database to a folder you choose. Updates the existing copy. Independently developed; does not sync changes back to Strongbox."

## Identität und bestehende Ordnerfreigaben

Das [Build-Skript](https://github.com/flowsworld/strongbox-sync-backup-mirror/blob/699ff21a4283e415ec5d7a4cc223581bd7fe506e/macos-app/build.zsh) setzt `cloud.diesis.sync-copies` als Bundle-ID, `Sync-Kopien` als Bundle-Namen und `SyncCopies` als ausführbare Datei. Ein neuer sichtbarer Name erfordert keine neue Bundle-ID. Apple behandelt die Bundle-ID als Systemidentität und lässt sie nach dem ersten hochgeladenen Build in App Store Connect nicht mehr ändern. `CFBundleName` und `CFBundleDisplayName` sind getrennte sichtbare Namenswerte. [CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier), [CFBundleDisplayName](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledisplayname)

Die [Ordnerfreigaben in Services.swift](https://github.com/flowsworld/strongbox-sync-backup-mirror/blob/699ff21a4283e415ec5d7a4cc223581bd7fe506e/macos-app/Sources/SyncCopies/Services.swift) verwenden `.withSecurityScope` mit `relativeTo: nil`, also app-scoped Bookmarks. Apple bindet deren Auflösung an dieselbe Code-Signing-Identität. Die bloße Beibehaltung der Bundle-ID garantiert daher keinen Übergang vom ad-hoc Build zur Produktionssignierung. [Apple: bookmarkData](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:))

Vorschlag für die Namensumsetzung: Bundle-ID, interne Einstellungen und gespeicherte Bookmarks beibehalten. Den Übergang zum endgültigen signierten Bundle getrennt prüfen, einschließlich Neustart und vorhandener Lese- und Schreibfreigaben. Bei einer absichtlich geänderten Identität sind Container-/Einstellungsmigration und erneute Ordnerfreigaben zu planen. Anzeigenamen allein sollen keine vorhandenen Freigaben verwerfen.

## Ungesendete Anfrage für Flo

Adressvorschlag: `info@phoebecode.com`, die auf About veröffentlichte Geschäftsadresse. Die Anfrage bittet ausdrücklich um Weiterleitung an die aktuell zuständige Stelle. Sie wurde nicht versendet.

> Subject: Permission to reference Strongbox in an independent paid macOS backup-copy utility
>
> Hello Strongbox team,
>
> I am Florian Gratzl, founder of DIESIS Media. I am developing an independent macOS menu bar utility that copies the latest local encrypted backup of selected Strongbox Sync databases to user-selected folders. It reads local metadata and backup files with user-granted folder access. It does not decrypt databases, write back to Strongbox, or access your sync service directly.
>
> I intend to offer it for a one-time purchase of approximately EUR 5, potentially through the Mac App Store and/or direct distribution. The final name is undecided. Options include an independent name such as "DIESIS Backup Copy", with a compatibility statement in the description, or "Backup Copy for Strongbox" and its German equivalent "Backup-Kopie für Strongbox". I would not use your logo or imply that this is an official Strongbox product.
>
> Could you confirm whether you permit these uses of the Strongbox name in the app title, in-app text, documentation and store/website descriptions? Please specify any required attribution, disclaimer, naming restrictions, distribution-channel conditions or approval process. Can you also confirm whether you permit this commercial read-only use of local metadata and backups, and whether there is a supported export or integration interface we should use instead?
>
> Your About page lists Phoebe Code Limited, while the announcement about joining Applause indicates a change in stewardship. Please forward this request to the current rights holder or authorised contact and identify who can grant the permission. Written confirmation that I can retain for App Review would be helpful.
>
> Kind regards,
> Florian Gratzl
> DIESIS Media

## Offene Entscheidung und Umsetzung

- [ ] Flo sendet die Anfrage, wenn er die Rechteklärung starten möchte. Keine externe Kontaktaufnahme durch diesen Rechercheauftrag.
- [ ] Antwort mit Datum, zuständiger Stelle, erlaubten DE-/EN-Formulierungen, Kanälen und Bedingungen hier festhalten. Keine Pflichtattribution erfinden; geforderte Formulierung exakt aufnehmen.
- [ ] Flo wählt den endgültigen deutschen und englischen Namen. Verfügbarkeit und mögliche Rechtekonflikte des gewählten Namens prüfen.
- [ ] Vertriebskanal festlegen und die Strongbox-Abhängigkeit für App Review klären. Händlerfreigabe und Apple-Zulassung getrennt nachweisen.
- [ ] Entscheidung hier dokumentieren: Name DE **offen**, Name EN **offen**, Freigabenachweis **offen**, Attribution **offen**, Vertriebskanal **offen**. Bundle-ID-Vorschlag **unverändert `cloud.diesis.sync-copies`**, noch keine Identitätsänderung beschlossen.
- [ ] Erst nach der Auswahl Bundle-Anzeigenamen, Menü, Mitteilungen, Dokumentation und Store-/Website-Material konsistent lokalisieren. Funktion und Unabhängigkeit korrekt beschreiben; keine noch ausstehende Google-Drive-Prüfung versprechen.
- [ ] Signierungsübergang und vorhandene Bookmarks gesondert verifizieren. Issue #8 bleibt bis zur Auswahl, dokumentierten Rechteklärung und Umsetzung offen.
