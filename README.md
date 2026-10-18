# claude-session-budget

[Français](#français) · [English](#english)

## Français

Un plafond de consommation par session Claude Code, sur la fenêtre de 5 h.
Tu tapes `budget:25` en début de prompt : la session sait qu'elle dispose de
25 % de la fenêtre, reçoit un rappel à 50, 80 et 100 %, et la status line
affiche `task 12/25`. Aucun blocage dur : au plafond, la session est invitée à
s'arrêter proprement et à résumer où elle en est.

Bash et `jq` uniquement. Aucune dépendance.

### Fonctionnement

Trois éléments, un fichier d'état par session.

| Élément | Rôle |
|---|---|
| `budget.sh prompt` (hook `UserPromptSubmit`) | Repère le préfixe `budget:N` ou `budget:off`, lit `quota.json`, écrit l'état de la session, injecte la phrase de budget. |
| `budget.sh tool` (hook `PostToolUse`, sans matcher) | Relit `quota.json`, injecte un rappel quand la consommation franchit 50, 80 ou 100 % du budget, une seule fois par seuil. |
| `budget.sh pre` (hook `PreToolUse`, sans matcher) | Verrou : dès 90 % du budget, refuse tout outil (sous-agents compris, même `session_id`) avec une raison courte : consommation, reste de la fenêtre 5 h, heure de réinitialisation, et les trois réponses possibles. Silencieux sinon, et sans autorisation `finish` active. |
| `budget.sh stop` (hook `Stop`) | Termine une autorisation `budget:finish` à la fin du tour. |
| `statusline.sh` | Écrit `quota.json` à chaque exécution, affiche la consommation de la fenêtre (`5h 19%`, le pourcentage utilisé, pas le reste) et le segment `task` (vert sous 80 %, orange de 80 à 100 %, rouge au-delà). |

Chaîne de données : la status line reçoit `rate_limits` de Claude Code et le
persiste dans `~/.claude/quota.json` (écriture atomique). Les hooks lisent ce
fichier. L'état de chaque session vit dans `~/.claude/budget/<session_id>.json`
(`start`, `cap`, `resets_at`, `fired`), écrit seulement par cette session.

`budget.sh status SID` sert à la status line : il imprime
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
  `budget:finish` (terminer l'étape en cours ; l'autorisation tombe à la fin du
  tour), `budget:N` (nouveau plafond de N points à partir de la consommation
  actuelle, état neuf), `budget:off` (tâche terminée : l'état est supprimé, le
  segment `task` disparaît). Un message ordinaire ne lève pas le verrou : le
  hook `UserPromptSubmit` le refuse (`decision: "block"`), sans coût modèle, et
  ne laisse passer que les préfixes `budget:`. La raison s'affiche à
  l'utilisateur seulement, Claude ne la reçoit pas.
- Fin de tâche : le segment `task` reste affiché tant que l'utilisateur n'a pas
  tapé `budget:off` (ou posé un nouveau `budget:N`) ; la phrase de pose demande à
  la session de lui proposer `budget:off` quand la tâche est terminée.
- Le préfixe `budget:N` n'est pas retiré du prompt : la doc des hooks ne permet
  pas de réécrire le prompt.
- `budget:N` doit être au tout début du prompt (espaces permis) et N un entier
  strictement positif.

### Installation

1. Copier `budget.sh` et `statusline.sh` dans `~/.claude/`. Si tu as déjà une
   status line, ne garde que le bloc qui écrit `quota.json` et le bloc `task`
   avant le `printf` final.
2. Dans `~/.claude/settings.json`, fusionner (sans remplacer les hooks existants) :

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/budget.sh prompt", "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/budget.sh pre", "timeout": 10 }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/budget.sh tool", "timeout": 10 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/budget.sh stop", "timeout": 10 }] }
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
bash test-budget.sh
```

101 vérifications, dans un `$HOME` temporaire, sans toucher à ta configuration :
pose, plafond borné, fenêtre pleine, quota inutilisable (absent, vide,
malformé, périmé), `off`, seuils une seule fois, saut de seuils, réinitialisation
de fenêtre, gigue de `resets_at`, deux sessions, `session_id` absent ou
dangereux, entrée illisible, purge par âge, réémission, segment de status line
(vert, orange, rouge, absent), verrou à 90 %, `finish`, nouveau plafond, `off`,
refus du prompt au verrou, fusion de `quota.json` (valeur périmée
ignorée, nouvelle fenêtre prise).
Variables de substitution utilisées par les
tests : `BUDGET_DIR`, `QUOTA_FILE`, `BUDGET_NOW`.

### Ce qui reste à tester dans une vraie session

Les tests simulent les entrées des hooks d'après la doc. Les points 1 à 3
ont été vus en session réelle le 2026-10-18 (voir la section suivante).

1. Recharger les hooks (`/hooks` ou redémarrage), ouvrir une session neuve et
   envoyer un message ordinaire (les `rate_limits` n'existent qu'après la
   première réponse API).
2. Envoyer `budget:3 lis une dizaine de fichiers et résume-les`. Attendu :
   segment `task 0/3` vert ; la session sait citer la phrase de budget ;
   `cat ~/.claude/budget/*.json` montre l'état.
3. Laisser consommer. Attendu : `task` passe à l'orange puis au rouge ; rappels à
   50, 80 et 100 % une seule fois chacun ; au plafond la session s'arrête et résume.
4. Envoyer `budget:off`. Attendu : fichier d'état supprimé, segment absent.
5. Points ouverts, à trancher par l'expérience :
   - **Reprise** : le `session_id` reste-t-il le même avec `--resume` ? La doc
     ne le dit pas. Lancer un budget, quitter, rouvrir avec `--resume`, regarder
     si `task` réapparaît.
   - **Sous-agents** : leurs appels d'outils déclenchent-ils `PostToolUse` avec
     le `session_id` du parent ?
   - **Décalage** : la status line n'écrit `quota.json` qu'à chaque événement et
     toutes les 60 s, donc le dernier rappel peut arriver un peu après le plafond.
   - **Format** de `used_percentage` : entier ou décimal ; les deux sont gérés,
     seul l'entier a été vu.
6. Diagnostic : `claude --debug` montre l'exécution des hooks. À la main :
   `echo '{"session_id":"x","prompt":"budget:3 test"}' | bash ~/.claude/budget.sh prompt`
   (supprimer ensuite `~/.claude/budget/x.json`).

### Observé en session réelle (2026-10-18)

Établi par l'expérience, avec `budget:3` sur une fenêtre neuve (départ 4 %).

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
  `budget.sh`.
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
  aucun `PostToolUse`. `budget.sh tool` ne voit pas les outils en échec.
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
de la fenêtre, heure de réinitialisation, trois réponses), puis `budget:off`
qui lève le verrou et supprime l'état. Le verrou ne touche que les outils : la
session continue de répondre en texte, ce qui coûte de la fenêtre.
Attention : le verrou bloque aussi `Edit` et `Write`, donc la session qui le
déclenche ne peut plus rien écrire avant `finish`, `N` ou `off`.

Vu en réel, troisième passe (`budget:3`, départ 41 %, plafond 44 %) :
- **Prompt refusé au verrou** : un « salut » sans préfixe a affiché
  `UserPromptSubmit operation blocked by hook`, la raison, puis
  `Original prompt: salut`. Le texte reste dans la zone de saisie. `budget:off`
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
  la fenêtre 5 h est protégée, `seven_day_*` n'est pas lu par `budget.sh`.
- **À vérifier en réel** : le fichier ne régresse plus avec plusieurs sessions
  ouvertes (relevé après coup, pas encore fait avec le correctif actif).

Limite de conception, non notée avant : le budget est un écart de
`used_percentage`, pourcentage global du compte. La consommation d'une autre
session fait avancer `task` (voir le point 3 de la prochaine session).

Non vu en réel : `budget:finish` (levée puis retombée à la fin du tour),
`budget:N` après verrou, sous-agent refusé et message à l'orchestrateur.

### Prochaine session, dans cet ordre

1. **Refuser le prompt au verrou : fait et vu en réel** (2026-10-18). Seuls les
   préfixes `budget:` passent. Reste à éprouver : `/clear` ou une commande
   intégrée passe-t-elle par ce hook (supposé que non).
2. **Status line figée sur une session au repos : résolu côté données** (2026-10-18,
   quatrième et cinquième passes). L'écran se repeint bien (horloge test) ; la cause
   était des sessions inactives qui écrasaient `quota.json` avec des valeurs
   périmées. Corrigé dans `statusline.sh` (fusion monotone par fenêtre). Reste :
   le `5h` affiché par une session inactive reste celui que Claude Code lui a
   transmis, donc en retard à l'écran ; non corrigible chez nous.
3. **Comptage par session** (à étudier, décision de conception). Aujourd'hui le
   budget est un écart de `used_percentage`, pourcentage global du compte : la
   consommation d'une autre session fait avancer `task`. Piste : sommer les
   tokens du transcript (`transcript_path`) pour isoler la session, en gardant
   le pourcentage global pour la fenêtre. Inconnus : conversion tokens en points
   de fenêtre (cache, modèle), tokens des sous-agents absents ou non du transcript
   parent. Observé : le transcript porte des tokens par message. Supposé : le reste.
4. **Outils en échec** : `PostToolUseFailure` (un `Read` sur un fichier absent n'a
   que `PreToolUse`). `budget:3` suffit.
5. Rappel et refus côté sous-agent, `--resume`, les cas du point 8 (deux sessions,
   `/clear`, `/compact`, `budget:` hors début, double pose, préfixe sans tâche),
   formule de réinitialisation jamais vue en réel, blocage par `Stop`.

6. **Renommer `budget` en `count`** (décidé : périmètre complet, pas seulement le
   préfixe). Touche le préfixe tapé (`count:N`, `count:off`, `count:finish`), les
   messages injectés, les noms de fichiers, les commandes de hooks dans
   `settings.json`, le dépôt et le submodule de `ai-tools`. **Décidé : pas d'alias**
   `budget:`. Un `budget:5` tapé par réflexe sera ignoré en silence, à garder en
   tête. À faire en dernier : le renommage change les chemins des
   fichiers actifs, donc recopier et recharger avec soin ; pousser le dépôt et
   le pointeur du submodule seulement sur ordre. Tests rouges d'abord.

Règles de la passe : un point à la fois, `budget:3` ou `budget:5` pour les essais,
aucun lancement manuel de `statusline.sh` avec de fausses valeurs, pas de
mémoire locale (tout vit ici).

### Pour qu'une autre session reprenne le travail

- Lire `budget.sh` en entier (environ 130 lignes) puis `test-budget.sh`.
- Toute modification de comportement commence par un test qui échoue dans
  `test-budget.sh`.
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
Start a prompt with `budget:25`: the session is told it has 25% of the window,
gets a reminder at 50, 80 and 100% of that budget, and the status line shows
`task 12/25`. There is no hard block: at the cap the session is asked to stop
cleanly and summarise where it stands.

Bash and `jq` only.

- `budget.sh prompt` (`UserPromptSubmit` hook) parses the prefix, reads
  `quota.json`, stores per-session state, injects the budget sentence.
- `budget.sh tool` (`PostToolUse` hook, no matcher) injects a reminder once per
  threshold (50, 80, 100%).
- `statusline.sh` writes `quota.json` (the status line is the only place
  `rate_limits` is exposed) and renders the `task` segment (green below 80%,
  orange 80 to 100%, red beyond).
- State lives in `~/.claude/budget/<session_id>.json`, one file per session,
  written atomically, purged after 24 h.
- If the 5-hour window resets mid-task, consumption is `(100 - start) + current`.
- Missing, empty, malformed or stale `quota.json`: nothing is invented, nothing
  is injected.
- The `budget:N` prefix stays in the prompt: hooks cannot rewrite it.

Install: see the settings snippet above. Tests: `bash test-budget.sh` (101 checks
in a throwaway `$HOME`). The French section lists what is still unverified in a
live session (resume, subagents, update lag).
