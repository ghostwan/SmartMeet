# Reste à faire

État au commit `07db7f4`. Classé par ce qui coûte le plus cher à ignorer.

---

## 1. En cours — notifications non fonctionnelles

Tout le code est écrit et compile, mais **aucune notification n'a jamais été délivrée
sur la machine de développement**. `requestAuthorization` échoue avec
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

**Fait qui oriente la suite** : un bundle minimal, *sans `LSUIElement` et en politique
d'activation `.regular`*, lancé depuis `/Applications`, obtient l'autorisation. Deux
variables ont changé simultanément dans ce test. À départager une par une :

1. **le mode agent** (`LSUIElement = true`) empêcherait l'enregistrement auprès de
   `usernoted`. Ennuyeux : une application menu-bar est agent par nature. Contournement
   éventuel — `NSApp.setActivationPolicy(.regular)` au moment de la demande, puis retour
   en `.accessory` ;
2. **le premier refus est mémorisé** et colle au bundle. Test : changer
   `CFBundleIdentifier` pour `com.smartmeet.app.test` et relancer le diagnostic. Si ça
   passe, il suffit de réinitialiser l'état côté système.

Tant que ce point n'est pas levé, la réponse à « suis-je prévenu quand le compte rendu
est prêt ? » reste **non** en pratique.

---

## 2. Bugs identifiés, non corrigés

### Types de réunion personnalisés ignorés par le stockage

`RecordingSession` construit `MeetingStore(customTemplates: settings.customTemplates)`
**une seule fois, à l'initialisation**. Créer ou modifier un type ensuite ne met pas le
store à jour : `summary.md` est alors rendu avec le type générique au lieu du type
retenu. Le compte rendu affiché dans l'application reste correct — seul le fichier
exporté est faux, ce qui rend le bug discret.

→ Passer les types au moment de l'écriture plutôt qu'à la construction.

### Page de sprint supprimée côté Confluence

Si la page référencée est supprimée, la publication échoue avec un 400 brut peu
parlant, sans repli vers l'accueil de l'espace. La détection existe déjà pour le cas
« aucune page définie », il reste à couvrir « page définie mais introuvable ».

### Changement de page de sprint en cours de sprint

Rien ne migre les comptes rendus déjà publiés, ce qui est probablement le comportement
souhaité, mais l'interface ne le dit pas.

### Recherche limitée aux métadonnées

`Meeting.matches` couvre titre, synthèse, participants et décisions — **pas le contenu
du transcript**. Chercher une phrase prononcée en réunion ne donne rien.

---

## 3. Prévu puis oublié

### Rappel de consentement

Identifié comme risque en phase 1, jamais implémenté. Enregistrer une réunion avec des
tiers exige leur accord. Il manque un rappel visible au démarrage d'un enregistrement,
et idéalement une mention dans le compte rendu publié.

C'est le point le plus embarrassant de cette liste : c'est une obligation légale, pas
un confort.

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

---

## 6. Dette et outillage

- `Scripts/ship.sh --skip-tests` contourne la vérification la plus utile. La suite
  tourne en 10 ms — aucune raison légitime de s'en servir aujourd'hui. À retirer.
- Les spikes de phase 0 (`Spikes/SpikeTap`, `Spikes/SpikeSTT`) sont conservés comme
  bancs d'essai mais ne sont plus exercés. À supprimer ou à intégrer aux tests.
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
| Types de réunion personnalisés | `defaults` | Réglages › Types de réunion. Les quatre types fournis sont dans le code. |
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
