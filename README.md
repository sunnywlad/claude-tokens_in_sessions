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
| `statusline.sh` | Écrit `quota.json` à chaque exécution, et affiche le segment `task` (vert sous 80 %, orange de 80 à 100 %, rouge au-delà). |

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
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/budget.sh tool", "timeout": 10 }] }
    ]
  },
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh", "refreshInterval": 60 }
}
```

3. Ouvrir `/hooks` une fois, ou redémarrer Claude Code, pour recharger les réglages.

### Tests automatiques

```
bash test-budget.sh
```

61 vérifications, dans un `$HOME` temporaire, sans toucher à ta configuration :
pose, plafond borné, fenêtre pleine, quota inutilisable (absent, vide,
malformé, périmé), `off`, seuils une seule fois, saut de seuils, réinitialisation
de fenêtre, gigue de `resets_at`, deux sessions, `session_id` absent ou
dangereux, entrée illisible, purge par âge, réémission, segment de status line
(vert, orange, rouge, absent). Variables de substitution utilisées par les
tests : `BUDGET_DIR`, `QUOTA_FILE`, `BUDGET_NOW`.

### Ce qui reste à tester dans une vraie session

Les tests simulent les entrées des hooks d'après la doc. Aucun n'a encore été
vu en situation réelle.

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

### Pour qu'une autre session reprenne le travail

- Lire `budget.sh` en entier (environ 130 lignes) puis `test-budget.sh`.
- Toute modification de comportement commence par un test qui échoue dans
  `test-budget.sh`.
- Ce dépôt contient des copies : les fichiers actifs sont ceux de `~/.claude/`.
  Après une modification, recopier dans les deux sens.
- Sources vérifiées dans la doc officielle des hooks (code.claude.com/docs/en/hooks) :
  `session_id` présent dans `UserPromptSubmit` et `PostToolUse` ;
  `hookSpecificOutput.additionalContext` accepté par les deux ;
  aucun champ pour réécrire le prompt.

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

Install: see the settings snippet above. Tests: `bash test-budget.sh` (61 checks
in a throwaway `$HOME`). The French section lists what is still unverified in a
live session (resume, subagents, update lag).
