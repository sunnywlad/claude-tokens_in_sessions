# claude-tokens_in_sessions

[Français](#français) · [English](#english)

## Français

Un plafond de consommation par session Claude Code, sur la fenêtre de 5 h.
Tu tapes `count:25` en début de prompt : la session sait qu'elle dispose de
25 % de la fenêtre, reçoit un rappel à 50, 80 et 100 %, et la status line
affiche `task 12/25`. Aucun blocage dur : au plafond, la session est invitée à
s'arrêter proprement et à résumer où elle en est.

Bash et `jq` uniquement. Aucune dépendance.

### Fonctionnement

Trois éléments, un fichier d'état par session.

| Élément | Rôle |
|---|---|
| `count.sh prompt` (hook `UserPromptSubmit`) | Repère le préfixe `count:N` ou `count:off`, lit `quota.json`, écrit l'état de la session, injecte la phrase de budget. |
| `count.sh tool` (hook `PostToolUse`, sans matcher) | Relit `quota.json`, injecte un rappel quand la consommation franchit 50, 80 ou 100 % du budget, une seule fois par seuil. |
| `count.sh pre` (hook `PreToolUse`, sans matcher) | Verrou : dès 90 % du budget, refuse tout outil (sous-agents compris, même `session_id`) avec une raison courte : consommation, reste de la fenêtre 5 h, heure de réinitialisation, et les trois réponses possibles. Silencieux sinon, et sans autorisation `finish` active. |
| `count.sh stop` (hook `Stop`) | Termine une autorisation `count:finish` à la fin du tour. |
| `statusline.sh` | Écrit `quota.json` à chaque exécution, affiche la consommation de la fenêtre (`5h 19%`, le pourcentage utilisé, pas le reste) et le segment `task` (vert sous 80 %, orange de 80 à 100 %, rouge au-delà). |

Chaîne de données : la status line reçoit `rate_limits` de Claude Code et le
persiste dans `~/.claude/quota.json` (écriture atomique). Les hooks lisent ce
fichier. L'état de chaque session vit dans `~/.claude/count/<session_id>.json`
(`start`, `cap`, `resets_at`, `fired`), écrit seulement par cette session.

`count.sh status SID` sert à la status line : il imprime
`consommé budget pourcentage`, ou rien.

### Règles de calcul

- Plafond = départ + N, borné à 100. Si la borne joue, la phrase injectée le dit.
- Même fenêtre (`resets_at` à moins de 60 s près) : consommé = `used_percentage`
  actuel moins départ.
- Fenêtre réinitialisée pendant la tâche : consommé = (100 moins départ) plus
  `used_percentage` actuel. Suppose une seule réinitialisation.
- Fenêtre déjà à 100 % à la pose : aucun budget posé, la session en est informée.
- `quota.json` absent, vide, malformé ou périmé (`resets_at` passé) : la pose
  est refusée avec un message, le hook d'outil ne dit rien et ne plante pas.
- Saut de plusieurs seuils d'un coup : un seul message, le plus haut ; les
  seuils inférieurs sont marqués tirés.
- Plusieurs sessions : états séparés par `session_id`, jamais de fichier partagé
  en écriture.
- États de plus de 24 h : purgés au prochain prompt de n'importe quelle session.
- Verrou à 90 % du budget : la session s'arrête et demande à l'utilisateur de
  choisir. Trois réponses, à taper en début de prompt :
  `count:finish` (terminer l'étape en cours ; l'autorisation tombe à la fin du
  tour), `count:N` (nouveau plafond de N points à partir de la consommation
  actuelle, état neuf), `count:off` (tâche terminée : l'état est supprimé, le
  segment `task` disparaît). Un message ordinaire ne lève pas le verrou : le
  hook `UserPromptSubmit` le refuse (`decision: "block"`), sans coût modèle, et
  ne laisse passer que les préfixes `count:`. La raison s'affiche à
  l'utilisateur seulement, Claude ne la reçoit pas.
- Fin de tâche : le segment `task` reste affiché tant que l'utilisateur n'a pas
  tapé `count:off` (ou posé un nouveau `count:N`) ; la phrase de pose demande à
  la session de lui proposer `count:off` quand la tâche est terminée.
- Le préfixe `count:N` n'est pas retiré du prompt : la doc des hooks ne permet
  pas de réécrire le prompt.
- `count:N` doit être au tout début du prompt (espaces permis) et N un entier
  strictement positif.

### Installation

1. Copier `count.sh` et `statusline.sh` dans `~/.claude/`. Si tu as déjà une
   status line, ne garde que le bloc qui écrit `quota.json` et le bloc `task`
   avant le `printf` final.
2. Dans `~/.claude/settings.json`, fusionner (sans remplacer les hooks existants) :

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/count.sh prompt", "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/count.sh pre", "timeout": 10 }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/count.sh tool", "timeout": 10 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/count.sh stop", "timeout": 10 }] }
    ]
  },
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh", "refreshInterval": 60 }
}
```

3. Rien à recharger : un hook ajouté à `settings.json` pendant une session
   ouverte est pris en compte dès l'outil suivant (observé le 2026-10-18).
   `settings.json` est global : toutes les sessions ouvertes en profitent, y
   compris celles qui ne demandent aucun budget.

### Tests automatiques

```
bash test-count.sh
```

202 vérifications, dans un `$HOME` temporaire, sans toucher à ta configuration :
pose, plafond borné, fenêtre pleine, quota inutilisable (absent, vide,
malformé, périmé), `off`, seuils une seule fois, saut de seuils, réinitialisation
de fenêtre, gigue de `resets_at`, deux sessions, `session_id` absent ou
dangereux, entrée illisible, purge par âge, réémission, segment de status line
(vert, orange, rouge, absent), verrou à 90 %, `finish`, nouveau plafond, `off`,
refus du prompt au verrou, fusion de `quota.json` (valeur périmée
ignorée, nouvelle fenêtre prise), affichage d'une session inactive (le plus frais
des deux, stdin ou `quota.json`).
Variables de substitution utilisées par les
tests : `COUNT_DIR`, `QUOTA_FILE`, `COUNT_NOW`.

### Ce qui reste à tester dans une vraie session

Les tests simulent les entrées des hooks d'après la doc. Les points 1 à 3
ont été vus en session réelle le 2026-10-18 (voir la section suivante).

1. Recharger les hooks (`/hooks` ou redémarrage), ouvrir une session neuve et
   envoyer un message ordinaire (les `rate_limits` n'existent qu'après la
   première réponse API).
2. Envoyer `count:3 lis une dizaine de fichiers et résume-les`. Attendu :
   segment `task 0/3` vert ; la session sait citer la phrase de budget ;
   `cat ~/.claude/count/*.json` montre l'état.
3. Laisser consommer. Attendu : `task` passe à l'orange puis au rouge ; rappels à
   50, 80 et 100 % une seule fois chacun ; au plafond la session s'arrête et résume.
4. Envoyer `count:off`. Attendu : fichier d'état supprimé, segment absent.
5. Points ouverts, à trancher par l'expérience :
   - **Reprise** : fait, vu en réel le 2026-10-19 (`count:2`, quitter par Ctrl+D,
     `claude --resume <id>`) : le `session_id` est identique et `task 0/2`
     réapparaît aussitôt, avant toute réponse API.
   - **Sous-agents** : leurs appels d'outils déclenchent-ils `PostToolUse` avec
     le `session_id` du parent ?
   - **Décalage** : la status line n'écrit `quota.json` qu'à chaque événement et
     toutes les 60 s, donc le dernier rappel peut arriver un peu après le plafond.
   - **Format** de `used_percentage` : entier ou décimal ; les deux sont gérés,
     seul l'entier a été vu.
6. Diagnostic : `claude --debug` montre l'exécution des hooks. À la main :
   `echo '{"session_id":"x","prompt":"count:3 test"}' | bash ~/.claude/count.sh prompt`
   (supprimer ensuite `~/.claude/count/x.json`).

### Observé en session réelle (2026-10-18)

Établi par l'expérience, avec `count:3` sur une fenêtre neuve (départ 4 %).

- **Pose** : le hook `UserPromptSubmit` a injecté la phrase de budget, que la
  session a pu citer mot pour mot. Le `session_id` de l'état est celui de la
  session. Le segment `task 0/3` s'est affiché.
- **Rappel 50 %** : reçu au premier événement après le franchissement
  (`used_percentage` passé à 6, soit 2/3).
- **Rappel 100 %** : reçu sur un `PostToolUse` de `Read`, après un lot de trois
  lectures parallèles. Un seul message pour trois outils.
- **Rappel 80 %** : jamais reçu seul. Avec N=3 et des pourcentages entiers, 80 %
  tombe à 2,4 points, donc le passage de 66 % à 100 % saute le seuil. Sous N=4
  environ, 80 % et 100 % sont indiscernables. Que le seuil sauté soit marqué
  dans `fired` n'a pas été relevé.
- **Décalage de `quota.json`** : quatre relevés consécutifs sans changement de
  `used_percentage` malgré des lectures entre-temps. Un appel Bash force le
  rafraîchissement de la status line, donc la réécriture du fichier : les
  relevés manuels faussent la mesure.
- **Non monotone** : `used_percentage` est passé de 5 à 4 en six secondes, dans la
  même fenêtre (`resets_at` identique). `measure` plafonne à 0, mais un rappel
  peut être retardé.
- **Coût** : environ 14 fichiers pour 2 points, puis environ 3 400 lignes de
  plus pour le troisième. Un point de fenêtre pèse beaucoup devant la
  granularité d'un petit budget.
- **Format de `quota.json`** : entiers observés pour `used_percentage` ;
  `resets_at` en secondes epoch, stable dans la fenêtre. Le fichier contient
  aussi `seven_day_used_percentage` et `seven_day_resets_at`, ignorés par
  `count.sh`.
- **Réinitialisation de fenêtre** : survenue entre deux relevés (18 puis 4),
  avant la pose. Aucune réinitialisation pendant une tâche budgétée : la
  formule reste non vérifiée en réel.

### Observé en session réelle, seconde passe (2026-10-18)

- **Source du quota** : le stdin de `PreToolUse`, `PostToolUse` et `Stop`
  contient `session_id`, `transcript_path`, `prompt_id`, `permission_mode`,
  `effort`, `tool_use_id` (et `duration_ms`, `tool_response` après l'outil),
  aucun `rate_limits`. Le transcript ne porte que des tokens par message. La
  status line reste la seule source : le décalage de `quota.json` est
  incompressible côté hook.
- **Outil long** : pendant un outil de 30 s (`duration_ms` 30101), aucun
  événement de la session n'est survenu entre `PreToolUse` et `PostToolUse`. Un
  hook ne peut agir qu'avant et après, jamais pendant.
- **`Stop`** : le stdin contient `stop_hook_active` (`false` observé),
  `last_assistant_message` et `background_tasks`. Le blocage de fin de tour
  reste à éprouver.
- **`PreToolUse`** : la doc accepte `additionalContext` et le refus
  (`permissionDecision: "deny"`). Il n'apporte pas d'information plus fraîche
  qu'un `PostToolUse`, puisque `quota.json` n'a pas bougé entre les deux.
- **Sous-agents** : leurs outils déclenchent `PreToolUse` et `PostToolUse` avec
  le `session_id` du **parent**, plus `agent_id` et `agent_type`. Ils
  consomment donc le budget du parent, comportement voulu. Un sous-agent de
  quatre appels (modèle haiku) a coûté 1 point de fenêtre sur 5.
- **Outil en échec** : un `Read` sur un fichier inexistant a un `PreToolUse` et
  aucun `PostToolUse`. `count.sh tool` ne voit pas les outils en échec.
- **`PostToolUse` de l'outil `Agent`** : tiré au lancement du sous-agent, pas à
  sa fin.
- **Fausse réinitialisation** : toute exécution de `statusline.sh` réécrit
  `quota.json`. Un essai manuel avec un `resets_at` inventé (écart de plus de
  60 s) a fait lire une réinitialisation, donc 101 consommés sur 5 et un faux
  rappel de plafond, avec `fired` rempli. Ne jamais lancer `statusline.sh` à la
  main avec de fausses valeurs ; les tests passent par un `$HOME` temporaire.
- **Pourcentages sous N=5** : seuils à 2,5, 4 et 5 points, atteints à 3, 4 et 5
  sur entiers, donc séparables si la consommation avance d'un point à la fois.

Dépassement constaté : 7 sur 5. Causes : un lot de cinq `Edit` en parallèle
(aucune alerte ne peut s'intercaler dans un lot), le décalage de `quota.json`,
et un message qui disait « termine l'action en cours », donc autorisait à
continuer. Réponse : le verrou `PreToolUse` à 90 %.

Vu en réel : un `Bash` refusé avec la raison complète reçue (consommation, reste
de la fenêtre, heure de réinitialisation, trois réponses), puis `count:off`
qui lève le verrou et supprime l'état. Le verrou ne touche que les outils : la
session continue de répondre en texte, ce qui coûte de la fenêtre.
Attention : le verrou bloque aussi `Edit` et `Write`, donc la session qui le
déclenche ne peut plus rien écrire avant `finish`, `N` ou `off`.

Vu en réel, troisième passe (`count:3`, départ 41 %, plafond 44 %) :
- **Prompt refusé au verrou** : un « salut » sans préfixe a affiché
  `UserPromptSubmit operation blocked by hook`, la raison, puis
  `Original prompt: salut`. Le texte reste dans la zone de saisie. `count:off`
  passe et lève le verrou.
- **Rappel 50 %** : reçu à `2/3`, sur le `PostToolUse` d'un lot de trois `Read`.
- **Rappel 100 %** : non reçu. Le verrou `PreToolUse` a vu 3/3 avant que le
  `PostToolUse` ne le voie ; quatre `Read` parallèles ont tous été refusés. Que
  100 soit dans `fired` n'a pas été relevé.
- **Coût** : 3 points de fenêtre pour une quarantaine de lectures, dont de
  gros fichiers relus en boucle. Le contexte est monté à 257k : un essai de
  consommation par relecture gonfle le contexte, donc le coût par appel.
- **Status line** : `task` a avancé (1/3 puis 3/3) pendant la tâche, orange à
  100 %. Pas de figement vu sur une session active.

Vu en réel, quatrième passe (session B ouverte à 22:06, `5h 51%`, laissée au
repos 24 min ; mesure par une ligne de journal ajoutée à `statusline.sh`, retirée
ensuite) :
- **Le script tourne au repos** : une exécution par minute, à seconde fixe, avec
  `rate_limits` à chaque fois. `used5` a bien suivi 51, 52, 53.
- **L'écran ne suit pas** : B est restée à `5h 51%` pendant toute la mesure,
  même au premier plan, même après une frappe dans la zone de saisie.
- **Un événement de session repeint** : l'envoi d'un message dans B a mis la
  ligne à jour. L'hypothèse tirée de là (Claude Code ignorerait la sortie
  périodique) est écartée par la cinquième passe.
- **Pas le même chiffre selon la session** : au même instant, `used5` reçu par
  deux sessions différait de 1 point (B à 52 trois secondes avant l'autre à 51).
- **Conséquence supposée, corrigée par la cinquième passe** : on croyait
  `quota.json` frais parce que la session au repos le réécrit ; en fait elle y
  écrivait une valeur périmée.

Cinquième passe (horloge `HH:MM:SS` temporaire dans la sortie, puis trace dans la
branche d'écriture de `quota.json`, retirées ensuite) :
- **Le repaint périodique marche** : l'horloge de B a avancé au repos. L'hypothèse
  « Claude Code jette la sortie périodique » est écartée. Non expliqué : à
  22:22, le journal disait 53 reçu par B alors que l'écran, sans horloge,
  affichait 51.
- **Cause trouvée : écrasement de `quota.json`** par les sessions inactives. À
  23:31-23:35, `adbc90e9` (reçoit 53) et `259e5df8` (reçoit 52) réécrivaient le
  fichier chaque minute, alors que la valeur réelle était 55 : le fichier
  oscillait 55, 53, 52, 55... Cela explique la valeur non monotone de la première
  passe (5 puis 4 en six secondes) et exposait le verrou à une consommation
  sous-estimée.
- **Correctif** (test rouge d'abord, 5 tests) : dans la même fenêtre (`resets_at`
  à moins de 60 s), une valeur plus basse ne remplace pas la valeur stockée ; une
  fenêtre plus ancienne est ignorée ; une fenêtre plus récente remplace. Seule
  la fenêtre 5 h est protégée, `seven_day_*` n'est pas lu par `count.sh`.
- **À vérifier en réel** : le fichier ne régresse plus avec plusieurs sessions
  ouvertes (relevé après coup, pas encore fait avec le correctif actif).

Limite de conception, non notée avant : le budget est un écart de
`used_percentage`, pourcentage global du compte. La consommation d'une autre
session fait avancer `task` (voir le point 4 de la prochaine session).

Non vu en réel : `count:finish` (levée puis retombée à la fin du tour),
`count:N` après verrou, sous-agent refusé et message à l'orchestrateur.

### Verrou de contexte et outils en échec (2026-10-19, vus en réel sauf `/clear` et `/compact`)

- **Verrou de contexte**, indépendant de `count:` : dès 150 000 tokens de contexte
  (entrée + cache écrit + cache lu du dernier message principal du transcript,
  sous-agents exclus), `PreToolUse` refuse tout outil et `UserPromptSubmit` bloque
  tout prompt. `unlock:` en début de prompt (collé accepté) lève le verrou
  (`<sid>.ctx.json`) ; il reprend à 180k puis à 220k, un `unlock:` par palier, et
  plus après le dernier. Sans verrou actif, `unlock:` est ignoré.
  `unlock:free` (début de prompt, collé accepté) supprime toute limite de contexte
  pour la session, verrou actif ou non, donc posable d'avance (style run de nuit) ;
  le verrou du compte `count:` reste actif, et un `/clear` donne un nouveau
  `session_id`, donc il faut le retaper.
  Seuils réglables par `COUNT_CTX_LIMIT` et `COUNT_CTX_STEPS`. Vu en réel :
  `unlock:` à 159k, message « prochain verrou à 180k » (le premier jet affichait
  « 180k180000 », corrigé, test rouge d'abord). `/compact` ne passe pas par le hook de prompt : vu
  en réel (2026-10-19), exécuté au verrou du compte sans refus, `task 1/1` conservé,
  contexte retombé à 0k. `/clear` non plus : passé au verrou sans refus, `task`
  disparu (nouveau `session_id`), ancien état laissé orphelin jusqu'à la purge à 24 h.
- **Outils en échec** : hook `PostToolUseFailure` (`count.sh fail`), mêmes seuils
  que `tool`, `fired` partagé. Vu en réel (`count:1`, départ 28 %) : après
  `count:finish`, un `Read` sur un fichier absent a déclenché le rappel « plafond
  atteint » par `PostToolUseFailure`. Avant, quatre lectures lourdes et quatre
  échecs n'ont pas fait bouger `used_percentage` (cache lu, peu cher) : le point
  s'est franchi par le travail normal. Le verrou `PreToolUse` à 1/1 a refusé
  l'outil suivant, donc l'essai d'un échec au plafond exige `count:finish`.

### Essais réels du point 6 (2026-10-19)

- **`/compact` et `/clear`** : ne passent pas par le hook de prompt (verrou du compte actif,
  aucun refus). `/clear` donne un nouveau `session_id`, l'ancien état reste orphelin 24 h.
- **`--resume`** : même `session_id`, `task` réapparaît aussitôt.
- **`unlock:free`** (fait, tests rouges d'abord, 186 verts) : supprime toute limite de contexte
  pour la session, verrou actif ou non ; le verrou `count:` reste ; à retaper après `/clear`.
- **Sous-agent sous `count:1`** (vu en réel) : un seul `Read` de la revue a coûté 1 point, donc
  dépassement avant tout refus possible. Puis `pre` a refusé `SubagentHandback`, l'outil par
  lequel le sous-agent livre son rapport : quatre retries (task 2/1, 75k tokens, 5 outils),
  fin sans rapport livré, travail perdu. De plus la `<task-notification>` de fin de sous-agent
  arrive comme un prompt et le hook de prompt l'a refusée : l'orchestrateur ne l'a pas reçue.
- **Correctif A fait** (test rouge d'abord, 191 verts) : `pre` laisse toujours passer
  `SubagentHandback`, sous le verrou du compte comme sous le verrou de contexte. Pas
  encore revu en réel.
- **Point B fait** (décision de Wladimir : oui, 197 verts, test rouge d'abord) : le hook de prompt
  laisse passer un prompt qui commence par `<task-notification>` au verrou du compte. Le verrou
  de contexte aussi (étendu sur ordre de Wladimir : perdre un rapport est pire). Essai réel 2026-10-19 : A confirmé (le sous-agent a livré son rapport sous `count:1`). B raté : le rapport est arrivé en `<agent-message from="...">`, pas en `<task-notification>`, et le hook l'a bloqué. Corrigé : les deux balises passent (202 verts), vu en réel (2e essai, `count:1`, task 2/1) : l'orchestrateur a reçu le rapport du sous-agent au verrou, sans refus de prompt. Texte d'origine : B, le hook de prompt laisse passer `<task-notification>` : décision
  de Wladimir en attente (rapport reçu au prix d'un tour de modèle, ou perdu).
- **`Stop`** : question ouverte, aucun cas d'usage (bloquer `Stop` force à continuer, l'inverse
  d'un plafond) ; clos « sans objet » (2026-10-19), sauf cas précis de Wladimir.

### Prochaine session, dans cet ordre

1. **Refuser le prompt au verrou : fait et vu en réel** (2026-10-18). Seuls les
   préfixes `count:` passent. `/compact` ne passe pas par ce hook (vu en
   réel, 2026-10-19). `/clear` non plus (nouveau `session_id`, état
   orphelin purgé à 24 h). Point clos.
2. **Status line figée sur une session au repos : corrigé et vu en réel**
   (2026-10-18, quatrième et cinquième passes). L'écran se repeint bien (horloge
   test). Deux causes : des sessions inactives écrasaient `quota.json` avec des
   valeurs périmées (fusion monotone par fenêtre dans `statusline.sh`), et le
   `5h` d'une session inactive restait celui de son stdin périmé : le script
   affiche maintenant le plus frais entre son stdin et `quota.json` (même
   fenêtre et plus haut, ou fenêtre plus récente). Vu en réel : la session B, inactive, a
   rattrapé le `5h` de l'active à la minute suivante, sans rien taper dedans
   (script pris en compte à chaud). Limite : une session seule, sans autre session active, ne se met à
   jour que par ses propres appels.
3. **Renommer `budget` en `count` : fait et vu en réel** (2026-10-19, `count:1`,
   départ 61 %, plafond 62 %). Fichiers `count.sh` et `test-count.sh`, préfixe
   `count:N`, `count:off`, `count:finish`, variables `COUNT_*`, dossier d'état
   `~/.claude/count/`, messages injectés ("Compte de tâche"), commandes de hooks
   dans `settings.json`, anciens fichiers de `~/.claude/` supprimés. Tests écrits
   rouges d'abord (62 échecs), puis verts (106). Dépôt renommé
   `claude-tokens_in_sessions` (GitHub, dossier local, remote, poussé en
   `6560235`). Modification de `.gitmodules` dans `ai-tools` non committée, le
   pointeur du submodule reste à `cf44e0f`.
   Vu en réel : pose (phrase injectée, état écrit, `task 0/1`), consommation
   (`task 1/1` orange à 62 %), refus du prompt au verrou sous le nouveau préfixe,
   `count:finish` puis `count:off` acceptés. Non vu : le rappel de 100 % en
   `PostToolUse` (le verrou a repris la main avant, comme à la troisième passe).
   **Pas d'alias** `budget:` : un `budget:5` tapé par réflexe est ignoré en
   silence. Le mot « budget » reste dans la prose de ce README pour le concept.
   Préfixes d'essai désormais `count:3` et `count:5`.
4. **Comptage par session** (à étudier, décision de conception). Aujourd'hui le
   budget est un écart de `used_percentage`, pourcentage global du compte : la
   consommation d'une autre session fait avancer `task`. Piste : sommer les
   tokens du transcript (`transcript_path`) pour isoler la session, en gardant
   le pourcentage global pour la fenêtre. Inconnus : conversion tokens en points
   de fenêtre (cache, modèle), tokens des sous-agents absents ou non du transcript
   parent. Observé : le transcript porte des tokens par message. Supposé : le reste.
   **Établi le 2026-10-19 (transcripts réels)** :
   - Un message API s'étale sur 2 à 3 lignes `assistant` (même `message.id`, même
     `usage`, 0 divergence sur 31 ids) : dédupliquer par `message.id`.
   - `usage` : `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`,
     `output_tokens` (réflexion incluse), plus `message.model`. L'effort n'a donc pas de
     poids propre, il agit sur les tokens.
   - Sous-agents : **absents** du transcript parent. Fichiers
     `<session>/subagents/agent-*.jsonl`, `sessionId` = parent, `isSidechain: true`.
   - `cost-state` (coût cumulé) n'est écrit qu'en dernière ligne, à la fin de la
     session : inutilisable en direct. Recoupement : le parseur donne 1 à 2 % de moins.
   - `compact_boundary` dans le même fichier, sans `usage`. Coût du résumé non établi.
   - Coût de calcul : 70 ms pour 4 Mo de transcript.
   - Collé dans l'invite, un prompt arrive enveloppé de `<pasted_content id="...">` :
     le préfixe `count:` collé était ignoré en silence. Corrigé (test rouge d'abord).
   - Fenêtre en cours (65 %) : 54 M tokens de cache lu, 1,4 M de cache écrit, 0,26 M de
     sortie pour Sonnet. Une seule observation : la conversion n'est pas dérivable.
   **Conception retenue** : le compteur de session devient des tokens pondérés
   (modèle × catégorie) convertis en points par un K étalonné, le pourcentage global
   restant la source pour la fenêtre. Poids de départ : rapports de prix de l'API, à
   vérifier. Limite : claude.ai, mobile et agents Hermes consomment la fenêtre sans
   transcript local et faussent K.
   **Étape 1 faite** : `count.sh tokens CHEMIN` (une ligne par modèle, sous-agents inclus)
   et `count.sh log` (hook `PostToolUse`, une ligne JSON par appel dans
   `~/.claude/count/calib.log`, sessions avec un `count:` actif seulement : `t`, `sid`,
   `used`, `resets_at`, `tokens` par modèle). Première lecture réelle : 4 lignes
   cohérentes ; 240k tokens de cache lu sans bouger `used`.
   **Étalonnage écarté (2026-10-19, Wladimir)** : il utilise Claude dans d'autres sessions, donc
   la fenêtre ne peut pas être isolée et K ne peut pas être étalonné proprement. Le point 4
   reste en l'état (étape 1 faite, journal `calib.log`), sans comptage en points.
   Texte antérieur, caduc : **Prochaine étape** : essais d'étalonnage (fenêtre seule, hors réinitialisation,
   compositions de tokens contrastées, au moins 5 points chacun), puis validation sur
   un essai tenu à part ; ensuite seulement, le comptage en points dans `count.sh`.
5. **Outils en échec : fait et vu en réel** (2026-10-19, voir la section
   précédente).
6. Rappel et refus côté sous-agent, `--resume`, les cas du point 8 (deux sessions,
   `/clear`, `/compact`, préfixe hors début, double pose, préfixe sans tâche),
   formule de réinitialisation jamais vue en réel, blocage par `Stop`.
7. **Piste : un mod Claude Code** (2026-10-19, à étudier, rien d'essayé). Les types de la version
   2.1.303 (skill `plugin-authoring`) exposent `$.session.usage()` : `{ startedAt, context,
   rateLimits (five_hour, seven_day), cost }`, les chiffres de la status line, donc pas plus frais
   (même écart entre sessions), mais sans `statusline.sh` ni `quota.json` ni fusion monotone.
   Un mod peut aussi réécrire le prompt (`on('prompt.submit')`, `next({ ...e, text })`), ce que les
   hooks ne permettent pas, refuser un outil (`on('tool.call')`), et déclarer une commande
   (`$.command.register`, un vrai `/count 5`). Non vérifié : `/compact` et `/clear` passent-ils par
   un mod, la fraîcheur de `rateLimits` dans un hook, `cost` utile au point 4. Ne sert pas les
   agents Hermes (point 8) ni ne résout la conversion tokens en points. Premier essai possible :
   un mod minimal qui affiche `$.session.usage()` à côté de `quota.json`.
8. **Adapter aux agents Hermes qui utilisent la subscription Claude** (à examiner,
   décision de conception, rien d'observé). Ces agents consomment la même
   fenêtre 5 h globale du compte. Questions ouvertes : passent-ils par Claude
   Code, donc par les hooks et la status line, ou par un autre client ? Sans
   hooks Claude Code, ni le préfixe, ni le verrou, ni le segment `task` ne
   s'appliquent, et il faudrait un autre point d'accroche. Lien avec le point 4 :
   un compteur par session (tokens du transcript) pourrait convenir à des agents
   sans status line.

Règles de la passe : un point à la fois, `count:3` ou `count:5` pour les essais,
aucun lancement manuel de `statusline.sh` avec de fausses valeurs, pas de
mémoire locale (tout vit ici).

### Pour qu'une autre session reprenne le travail

- Lire `count.sh` en entier (environ 130 lignes) puis `test-count.sh`.
- Toute modification de comportement commence par un test qui échoue dans
  `test-count.sh`.
- Ce dépôt contient des copies : les fichiers actifs sont ceux de `~/.claude/`.
  Après une modification, recopier dans les deux sens.
- Sources vérifiées dans la doc officielle des hooks (code.claude.com/docs/en/hooks) :
  `session_id` présent dans `UserPromptSubmit` et `PostToolUse` ;
  `hookSpecificOutput.additionalContext` accepté par les deux ;
  aucun champ pour réécrire le prompt ;
  `UserPromptSubmit` peut refuser un prompt (`decision: "block"` + `reason`, ou
  sortie 2) : le prompt n'atteint pas Claude, `reason` n'est montrée qu'à
  l'utilisateur, le texte reste dans le transcript et l'historique.

## English

A per-session consumption cap for Claude Code on the 5-hour rate-limit window.
Start a prompt with `count:25`: the session is told it has 25% of the window,
gets a reminder at 50, 80 and 100% of that budget, and the status line shows
`task 12/25`. There is no hard block: at the cap the session is asked to stop
cleanly and summarise where it stands.

Bash and `jq` only.

- `count.sh prompt` (`UserPromptSubmit` hook) parses the prefix, reads
  `quota.json`, stores per-session state, injects the budget sentence.
- `count.sh tool` (`PostToolUse` hook, no matcher) injects a reminder once per
  threshold (50, 80, 100%).
- `statusline.sh` writes `quota.json` (the status line is the only place
  `rate_limits` is exposed) and renders the `task` segment (green below 80%,
  orange 80 to 100%, red beyond).
- State lives in `~/.claude/count/<session_id>.json`, one file per session,
  written atomically, purged after 24 h.
- If the 5-hour window resets mid-task, consumption is `(100 - start) + current`.
- Missing, empty, malformed or stale `quota.json`: nothing is invented, nothing
  is injected.
- The `count:N` prefix stays in the prompt: hooks cannot rewrite it.

Install: see the settings snippet above. Tests: `bash test-count.sh` (202 checks
in a throwaway `$HOME`). The French section lists what is still unverified in a
live session (resume, subagents, update lag).
