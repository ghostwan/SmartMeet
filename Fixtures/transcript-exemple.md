# Transcript — Réunion hebdo Home + Security
Date : 11/09/2026 — Durée : 32 min

**[00:00] Moi :** Bonjour à tous. On a trois sujets aujourd'hui : la migration Crowdin, le retard sur l'API de la caméra intérieure, et la préparation de la bêta iOS.

**[00:18] Participants :** Salut Alex. Sur Crowdin, j'ai terminé l'intégration de l'API côté build. Il reste la validation des traductions allemandes et italiennes, c'est Sandra qui doit passer dessus.

**[00:41] Moi :** Sandra, tu penses pouvoir boucler ça pour vendredi ?

**[00:47] Participants :** Vendredi c'est trop juste, j'ai la revue de specs ACME en parallèle. Je peux m'engager sur mardi prochain si personne ne rajoute de clés d'ici là.

**[01:05] Moi :** OK, on gèle les nouvelles clés Crowdin jusqu'à mardi alors. Je préviens l'équipe produit.

**[01:20] Participants :** Sur l'API caméra, on a deux semaines de retard. Le firmware ne renvoie pas les événements de détection de mouvement dans le bon format, l'équipe embarquée dit que c'est un problème de sérialisation protobuf.

**[01:48] Moi :** Deux semaines, ça impacte la bêta ?

**[01:52] Participants :** Oui. Si on ne débloque pas avant le 25, la bêta iOS glisse d'un sprint. Martin propose un contournement côté cloud : on normalise le payload dans le gateway plutôt que d'attendre le fix firmware.

**[02:20] Moi :** Le contournement, c'est combien de jours ?

**[02:24] Participants :** Trois jours de dev, plus un jour de tests. Mais ça crée de la dette : il faudra le retirer quand le firmware sera corrigé.

**[02:40] Moi :** On y va. C'est mieux qu'un sprint de retard. Martin, tu ouvres un ticket pour le contournement et un autre pour le retrait de la dette, qu'on ne l'oublie pas.

**[02:58] Participants :** Noté. Je les crée aujourd'hui.

**[03:05] Moi :** Dernier point, la bêta iOS. On en est où sur le recrutement des testeurs ?

**[03:14] Participants :** 340 inscrits sur les 500 visés. Le recrutement via la newsletter a mieux marché que prévu. On peut ouvrir à d'autres pays si besoin.

**[03:32] Moi :** Ouvre l'Allemagne et l'Espagne. On décide du go/no-go bêta au comité du 18.

**[03:45] Participants :** Une question : est-ce qu'on communique sur le retard caméra aux testeurs ?

**[03:52] Moi :** Non, pas tant que le contournement n'est pas validé en test. On réévalue le 18.
