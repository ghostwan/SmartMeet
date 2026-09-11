# SmartMeet

Enregistre une réunion sur macOS, la transcrit sur l'appareil, en génère le compte
rendu, et le publie sur Confluence avec les action items en tickets Jira.

Application menu-bar native. Aucun audio ne quitte la machine : la capture et la
transcription sont entièrement locales.

## Ce qui le distingue

**Diarisation par séparation physique.** Le micro et l'audio système sont capturés sur
deux pistes distinctes, via un *process tap* Core Audio — pas de pilote virtuel type
BlackHole. Ce qui vient du micro est vous, ce qui vient du système est un participant
distant. Aucun modèle de diarisation n'est nécessaire.

**Types de réunion.** Le compte rendu n'a pas un format unique. Un daily ouvre sur les
points bloquants et détaille le point de chaque personne ; une rétrospective ouvre sur
le ressenti nominatif de l'équipe puis regroupe les échanges par sujet, sans attribuer
aucun propos. Le type choisi pilote à la fois le schéma demandé au modèle et l'ordre de
rendu.

## Prérequis

macOS 26 ou supérieur, Apple Silicon, Xcode 26.

Pour la génération du compte rendu, au choix :

- [`opencode`](https://opencode.ai) — utilise un abonnement GitHub Copilot ;
- [`ollama`](https://ollama.com) — entièrement local, aucune donnée ne sort.

## Installation

```sh
./Scripts/bundle-app.sh
open build/SmartMeet.app
```

Le bundle est signé avec la première identité de développement trouvée dans le
trousseau. Pour en imposer une autre :

```sh
SMARTMEET_SIGN_IDENTITY="Apple Development: …" ./Scripts/bundle-app.sh
```

> Le bundle **doit** être lancé par LaunchServices (`open`), pas depuis un terminal.
> Exécuté directement, le processus responsable est le terminal : TCC n'attribue pas
> la permission de capture audio et le tap renvoie du silence, sans la moindre erreur.

## Utilisation

Choisissez un type de réunion dans le menu, cliquez **Enregistrer**. Le transcript
s'affiche au fil de l'eau. À l'arrêt, le compte rendu est généré, puis relisible et
modifiable avant publication.

Chaque réunion est un dossier autonome :

```
~/Library/Application Support/SmartMeet/Meetings/<uuid>/
    meeting.json     métadonnées et compte rendu
    segments.json    transcript structuré
    transcript.md    transcript lisible
    summary.md       compte rendu au format du type de réunion
    microphone.caf   piste utilisateur
    system.caf       piste participants
```

### Types fournis

| Type | Sections, dans l'ordre |
|---|---|
| Réunion générique | synthèse, décisions, action items, sujets, questions ouvertes, prochaines étapes |
| Daily | **points bloquants**, point par personne, action items, synthèse |
| Synchro | synthèse, décisions, action items, sujets, questions ouvertes, prochaines étapes |
| Rétrospective | **ressenti nominatif**, sujets dépersonnalisés, action items, décisions |

Ils se dupliquent et se modifient dans *Réglages › Types de réunion* : sections,
ordre, et consignes de rédaction envoyées au modèle.

### Mode headless

Utile pour le diagnostic et les tests bout en bout.

```sh
# enregistre 30 s, transcrit, génère le compte rendu
open -W build/SmartMeet.app --args --headless 30 /tmp/rapport --summarize

# génère un compte rendu à partir d'un transcript existant
./build/SmartMeet.app/Contents/MacOS/SmartMeet \
    --summarize-file Fixtures/transcript-daily.md \
    --template builtin.daily --publish
```

## Configuration

*Réglages › Atlassian* : site, e-mail, jeton d'API, espace Confluence, projet Jira.
Le jeton est conservé dans le trousseau. Au premier lancement, il est repris depuis
`ATLASSIAN_API_TOKEN` s'il est présent dans l'environnement.

Certains projets Jira imposent un epic parent via un validateur de workflow, que
l'API `createmeta` ne déclare pas. Le champ *Epic parent* couvre ce cas.

## Architecture

```
Sources/
├── AudioCapture/     process tap Core Audio, micro, horloge commune
├── Transcription/    SpeechAnalyzer, fusion des pistes, filtre de diaphonie
├── Summarization/    types de réunion, prompts, providers LLM
├── Atlassian/        Confluence, Jira, rendu storage
├── Calendar/         détection de la réunion via EventKit
├── MeetingStore/     persistance sur disque
└── SmartMeetApp/     interface menu-bar
Spikes/               bancs d'essai de validation technique
```

## Limites connues

- **Diaphonie.** Sans casque, les haut-parleurs reviennent dans le micro et les deux
  pistes transcrivent la même parole. L'annulation d'écho matérielle
  (`setVoiceProcessingEnabled`) est inutilisable ici : le traitement de voix d'Apple
  s'approprie le périphérique de sortie et prive le tap système de sa source. La
  correction se fait donc sur le texte (`CrossTalkFilter`), avec des seuils empiriques.
- Les noms propres métier sont approximés par la transcription, malgré l'injection de
  vocabulaire. Un casque améliore nettement le résultat.
- Le changement de périphérique audio en cours de réunion provoque une discontinuité.
- Les modèles locaux (`ollama`) résolvent moins fiablement les dates relatives.

## Développement

```sh
swift build
swift test
```
