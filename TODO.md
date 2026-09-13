# Reste à faire

Classé par ce qui coûte le plus cher à ignorer. Voir l'historique git pour la
progression : les points corrigés sont retirés au fur et à mesure, pas simplement
cochés ici.

---

## 1. En cours — notifications non fonctionnelles

Tout le code est écrit et compile, mais **aucune notification n'a jamais été délivrée
sur une machine de développement**. `requestAuthorization` échoue avec
`Notifications are not allowed for this application`, et l'application n'apparaît
jamais dans `~/Library/Preferences/com.apple.ncprefs.plist`.

Diagnostic disponible :

```sh
open build/SmartMeet.app --args --check-notifications /tmp/rapport.txt
```

**Écarté par l'expérience** (ne pas refaire) :

- la localisation seule — l'échec persiste depuis `/Applications` ;
- le hardened runtime et l'identité de signature — testé en Apple Development et ad-hoc ;
- l'absence de `NSApplication` — c'était un vrai défaut du diagnostic, corrigé, sans
  effet sur le résultat ;
- une politique MDM — le profil `com.apple.notificationsettings` présent ne liste que
  deux bundles Microsoft et ne restreint pas les autres.
- **le mode agent** (`LSUIElement`) — `MeetingNotifier.prepare()` bascule désormais en
  `.regular` le temps de `requestAuthorization`, avant de revenir en `.accessory`. Testé
  sur une machine sans identité de signature stable (signature ad-hoc, qui change à
  chaque build) : le refus persiste. Soit l'hypothèse était fausse, soit une signature
  instable interdit toute mémorisation d'autorisation avant même de poser la question —
  **à revérifier sur la machine de développement habituelle, avec une identité de
  signature stable**, où le point de départ (bundle minimal en `.regular`) avait
  fonctionné.

**Reste à tester** :

- **le premier refus est mémorisé** et colle au bundle. Test : changer
  `CFBundleIdentifier` pour `com.smartmeet.app.test` et relancer le diagnostic. Si ça
  passe, il suffit de réinitialiser l'état côté système.

Tant que ce point n'est pas levé, la réponse à « suis-je prévenu quand le compte rendu
est prêt ? » reste **non** en pratique.

---

## 2. Bugs identifiés

### Recherche à étendre aux nouveaux contenus

`Meeting.matches` couvre désormais titre, synthèse, transcript, participants et
décisions (le transcript est lu depuis `MeetingStore` au moment de filtrer). Si de
nouveaux champs texte s'ajoutent au compte rendu, penser à les inclure dans le
haystack de `RecordingSession.filteredMeetings`.

---

## 3. Prévu puis oublié

### Onboarding du téléchargement des modèles

Le téléchargement des assets de langue se fait silencieusement dans
`TrackTranscriber.start()`, derrière un simple « Préparation des modèles… ». Au premier
lancement, sur une connexion lente, l'utilisateur ne voit aucune progression et peut
croire à un blocage. Un écran d'accueil avec barre de progression était prévu.

### Re-transcription depuis l'audio conservé

`Meeting.trackStartOffsets` est persisté **exactement pour ça** — réaligner un
transcript recalculé a posteriori — mais rien ne l'utilise. Les deux pistes `.caf` sont
pourtant conservées. Permettrait de re-transcrire avec un meilleur modèle, une autre
langue, ou après correction du vocabulaire métier.

---

## 4. Non vérifié — risques ouverts

Par ordre de probabilité de mauvaise surprise :

| Zone | Ce qui n'a jamais été exercé |
|---|---|
| **Vraie réunion** | Aucun enregistrement réel avec plusieurs humains. Tout est validé sur synthèse vocale et fixtures écrites à la main, donc trop propres et trop bien structurées. |
| **Réunion longue** | Le chemin map-reduce (> 48 000 caractères) est testé unitairement, jamais exercé de bout en bout. |
| **Rendu Confluence des nouvelles sections** | `sprintWeather` et `fourL` ne sont validés que par tests unitaires. Une seule publication réelle a eu lieu et a été supprimée. |
| **Détection en conditions réelles** | La primitive Core Audio est prouvée, la logique de décision testée, mais aucune vraie visioconférence n'a déclenché de proposition. |
| **Changement de périphérique audio** | Brancher un casque en cours de réunion reconstruit le convertisseur et provoque une discontinuité, jamais mesurée. |
| **Page Confluence supprimée** | Le repli `AtlassianError.pageNotFound` (voir `PublishService.resolveDestination`) n'a été exercé qu'en lecture de code, jamais contre une vraie page supprimée. |
| **Rappel de consentement** | La bannière affichée pendant l'enregistrement (`MenuBarContent.consentReminder`) n'a jamais été vue par un participant réel ; son emplacement et sa formulation méritent un avis extérieur. |
| **Édition des types fournis** | Les quatre types de base (`Daily`, `Synchro`, `Rétrospective`, `Générique`) sont désormais éditables directement (stockés comme surcharge dans `customTemplates`, réinitialisables). Jamais testé au-delà de la compilation et des tests unitaires existants — pas de nouveau test dédié à ce mécanisme de surcharge. |

---

## 5. Qualité connue, à améliorer

### Diaphonie

`CrossTalkFilter` repose sur des seuils empiriques (3 s de tolérance, 50 % de
recouvrement) calibrés sur des cas de test, pas sur de vraies réunions. À régler sur du
matériel réel.

L'annulation d'écho matérielle reste inutilisable : `setVoiceProcessingEnabled(true)`
prive le tap système de sa source. Une annulation d'écho logicielle — la piste système
est connue, donc soustractible de la piste micro — n'a pas été explorée et serait la
vraie solution.

### Noms propres métier

« migration Crowdin » ressort en « migration coronale » malgré l'injection de
vocabulaire dans `AnalysisContext.contextualStrings`. À rejuger sur voix humaine avant
d'investir : la synthèse vocale prononce mal les noms propres, le problème est
peut-être surestimé.

### Icône météo

L'icône retenue est une interprétation du modèle : « éclaircie » est ressorti en
arc-en-ciel sur un essai. Corrigeable en un clic dans la relecture, mais pas fiable.

### Modèles locaux

`ollama` résout moins fiablement les dates relatives — « mardi prochain » tombé un
mercredi. Acceptable pour un repli, pas pour un usage principal.

### Identification des locuteurs

La piste système regroupe tous les participants distants sous un seul libellé. Les noms
viennent uniquement du calendrier, et c'est le modèle qui attribue les propos. Une vraie
diarisation intra-piste améliorerait nettement les dailys et les rétrospectives.

Ces cinq points ont en commun de ne pouvoir être tranchés que sur du matériel réel
(vraies voix, vrai réseau, vrai accent) : aucune fixture écrite à la main ne les
départagera. Ne pas les rouvrir tant qu'une vraie réunion n'a pas été enregistrée
(voir section 4).

---

## 6. Dette et outillage

- Aucune intégration continue. Le dépôt est personnel, mais `ship.sh` fait déjà tout ce
  qu'il faudrait exécuter.
- Pas de gestion de version ni de distribution : ni notarisation, ni mise à jour.

---

## 7. Idées non engagées

- Choisir la langue du compte rendu **après coup** et régénérer, plutôt qu'avant
  l'enregistrement seulement.
- Générer les deux langues d'un coup pour les réunions à audience mixte.
- Détecter la fin de réunion — l'application de visio libère le micro — et proposer
  d'arrêter l'enregistrement.
- Rattacher automatiquement un compte rendu à la page de sprint *de la date de la
  réunion* plutôt qu'à la page courante, utile en cas de publication différée.
- Rechercher une page parente par titre dans les réglages, au lieu de coller une URL.

---

## 8. Reprendre sur une autre machine

Ce qui ne vit **pas** dans le dépôt et devra être refait :

| Élément | Où il est | À refaire |
|---|---|---|
| Identité de signature | Trousseau | Une identité de développement Apple suffit. `bundle-app.sh` prend automatiquement la première trouvée ; sinon `SMARTMEET_SIGN_IDENTITY="…"`. |
| Jeton d'API Atlassian | Trousseau (`com.smartmeet.atlassian`) | Réglages › Atlassian. Repris de `ATLASSIAN_API_TOKEN` au premier lancement s'il est dans l'environnement. |
| Espace, projet Jira, epic parent, page de sprint | `defaults` de `com.smartmeet.app` | Réglages › Atlassian. |
| Types de réunion personnalisés, y compris surcharges des types fournis | `defaults` | Réglages › Types de réunion. Les quatre types fournis restent dans le code, mais une édition locale prime tant qu'elle existe (voir `AppSettings.upsert`/`remove`). |
| Autorisations micro, capture audio, calendrier, notifications | TCC | Redemandées au premier lancement. **Le bundle doit être lancé par LaunchServices** (`open build/SmartMeet.app`), jamais depuis un terminal, sinon la capture audio système renvoie du silence sans erreur. |
| Modèles de langue `SpeechTranscriber` | Système | Téléchargés au premier enregistrement. |
| Réunions enregistrées | `~/Library/Application Support/SmartMeet/Meetings/` | Non versionnées. Copier le dossier si besoin. |

Prérequis : macOS 26, Apple Silicon, Xcode 26. Puis `opencode` ou `ollama` pour la
génération du compte rendu.

Vérification que tout est en place :

```sh
swift test                                   # 100 tests
./Scripts/bundle-app.sh && open build/SmartMeet.app
open build/SmartMeet.app --args --check-notifications /tmp/rapport.txt
```

