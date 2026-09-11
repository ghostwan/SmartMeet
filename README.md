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
aucun propos. Le type choisi pilote le schéma demandé au modèle, l'ordre de rendu, le
titre de la page et sa destination.

**Page de sprint.** On la fixe une fois en début de sprint ; tous les comptes rendus de
réunions du sprint s'y rattachent ensuite, sans rien reconfigurer.

**Langue de sortie.** Le compte rendu se produit en français ou en anglais,
indépendamment de la langue parlée. Le choix se fait avant l'enregistrement : il
conditionne le prompt, pas seulement la mise en forme.

**Détection des réunions.** Quand une réunion démarre, SmartMeet propose de
l'enregistrer par une notification actionnable. La détection croise deux signaux : le
calendrier, qui dit ce qui *devrait* avoir lieu, et l'application de visioconférence
qui capte le micro, qui dit ce qui a *réellement* commencé.

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

Quand une réunion est détectée, une notification propose de l'enregistrer : *Enregistrer*
ou *Pas maintenant*. Le titre et les participants sont repris du calendrier. Sinon,
choisissez un type de réunion dans le menu et cliquez **Enregistrer**.

### Détection

Deux signaux, délibérément croisés :

| Signal | Ce qu'il apporte | Ce qui lui manque |
|---|---|---|
| Calendrier (EventKit) | titre, participants | déclenche sur des réunions annulées ou décalées |
| Micro capté par une app de visio (Core Audio) | preuve que la réunion a commencé | ne connaît ni titre ni participants |

Règles retenues :

- une application dédiée (Teams, Zoom, Webex, Slack, Meet…) qui capte le micro suffit,
  même sans événement au calendrier ;
- un **navigateur** qui capte le micro est trop ambigu — test de micro, vidéo, dictée —
  et n'est retenu que si le calendrier confirme ;
- un événement seul ne déclenche que s'il porte un lien de visioconférence, sinon toute
  réunion physique ou tout créneau bloqué donnerait une proposition.

Une proposition écartée ne revient pas pour la même réunion, et les propositions se
réarment à la fin d'un enregistrement.

Le démarrage automatique sans confirmation existe dans les réglages mais reste
**désactivé par défaut** : enregistrer des personnes sans les prévenir n'est pas un
comportement à activer à leur place.

Le reste du temps : choisissez un type de réunion dans le menu, cliquez **Enregistrer**. Le transcript
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

| Type | Sections, dans l'ordre | Titre | Destination |
|---|---|---|---|
| Réunion générique | synthèse, décisions, action items, sujets, questions ouvertes, prochaines étapes | `{summary} — {date}` | espace par défaut |
| Daily | **points bloquants**, point par personne, action items, synthèse | `Daily {Weekday} {date}` | page de sprint |
| Synchro | synthèse, décisions, action items, sujets, questions ouvertes, prochaines étapes | `{summary} — {Weekday} {date}` | page de sprint |
| Rétrospective | **météo du sprint**, 4L dépersonnalisés, action items, décisions | `{type} — {date}` | page de sprint |

Ils se dupliquent et se modifient dans *Réglages › Types de réunion* : sections, ordre,
consignes de rédaction, format de titre et destination.

### Rétrospective : météo du sprint et 4L

La rétrospective produit deux parties de nature opposée.

**Météo du sprint** — nominative, destinée à être transmise aux managers. Chaque
membre choisit une ou plusieurs images météo (☀️ 🌤️ ☁️ 🌧️ ⛈️ 🌫️ ❄️ 🌈 💨 🔥) pour
illustrer son sprint, explique son choix, puis raconte son sprint. Le compte rendu
restitue ses propos avec leurs nuances plutôt que de les lisser — c'est le seul moyen
qu'un manager y trouve autre chose qu'un résumé aseptisé. Seul l'oral est pris en
compte : les post-its et le tableau ne sont pas dans le transcript.

**4L** — dépersonnalisés. *Ce qui a plu*, *Ce qu'on a appris*, *Ce qui a manqué*, *Ce
qu'on aurait voulu*. Les remarques sont regroupées par thème et aucun propos n'est
attribué, ce qui permet d'aborder les sujets sensibles sans mettre personne en cause.

### Titre des pages

Le titre produit par le modèle varie d'une réunion à l'autre, ce qui rend
l'arborescence Confluence illisible. Le format reprend la main dessus :

| Jeton | Rendu |
|---|---|
| `{summary}` | titre proposé par le modèle |
| `{type}` | nom du type de réunion |
| `{Weekday}` / `{weekday}` | `Lundi` / `lundi` |
| `{date}` | `7 septembre 2026` |
| `{shortDate}` | `07/09/2026` |
| `{isoDate}` | `2026-09-07` |
| `{time}` | `14:30` |

Confluence refusant deux pages de même titre dans un espace, une collision est
résolue par un suffixe `(2)`, `(3)`…

Les parties littérales du format ne sont pas traduites : c'est une convention de
nommage, pas du contenu. Seuls les jetons de date suivent la langue du compte rendu.

### Destination

Chaque type publie vers l'une de ces cibles :

- **page de sprint courante** — définie dans *Réglages › Atlassian*, en collant l'URL
  de la page. L'espace est déduit de la page. Tant qu'aucune page n'est définie, les
  comptes rendus vont à l'accueil de l'espace plutôt que d'échouer ;
- **page fixe** — identifiant ou URL Confluence ;
- **accueil de l'espace**.

La destination effective est affichée dans le menu et avant publication.

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
├── Calendar/         détection : calendrier et applications de visio
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
- L'icône météo retenue par le modèle est une interprétation : « éclaircie » peut
  ressortir en arc-en-ciel. Elle se corrige en un clic dans la fenêtre de relecture.

## Développement

```sh
swift build
swift test
```

L'icône est dessinée en code (`Scripts/make-icon.swift`) et régénérée à chaque
assemblage du bundle : elle reste modifiable et lisible en diff, plutôt que d'être
un binaire opaque dans le dépôt.
