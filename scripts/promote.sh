#!/bin/sh
# Copie les versions validées d'un environnement vers le suivant et ouvre la MR (GitLab) ou la PR (GitHub).
# usage : scripts/promote.sh integration preprod
#         scripts/promote.sh preprod prod
# Le fichier est copié entier : tout ce qui a été validé dans l'environnement précédent passe d'un bloc.
# Pour ne promouvoir qu'un paquet, modifiez la ligne à la main dans une MR ordinaire.
set -eu
FROM="$1"; TO="$2"
SRC="inventories/$FROM/group_vars/all/versions.yml"
DST="inventories/$TO/group_vars/all/versions.yml"
TITLE="Promotion des versions : $FROM vers $TO"

if cmp -s "$SRC" "$DST"; then
  echo "Rien à promouvoir : $TO a déjà les versions de $FROM"; exit 0
fi

# Forge : GitLab (options de push) ou GitHub (gh pr create)
if [ -n "${GITLAB_CI:-}" ]; then FORGE=gitlab
elif [ -n "${GITHUB_ACTIONS:-}" ]; then FORGE=github
elif git remote get-url origin | grep -q 'github\.com'; then FORGE=github
else FORGE=gitlab
fi

if [ -n "${CI:-}" ]; then                 # en CI : identité et jeton du robot de promotion
  git config user.name  "promotion-bot"
  git config user.email "promotion-bot@noreply.exemple.local"
  if [ "$FORGE" = gitlab ]; then
    REMOTE="https://promotion-bot:${PROMOTION_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
  else
    # Un jeton dédié (GitHub App ou PAT) : une PR ouverte avec le GITHUB_TOKEN ne déclenche pas la CI
    REMOTE="https://x-access-token:${PROMOTION_TOKEN}@${GITHUB_SERVER_URL#https://}/${GITHUB_REPOSITORY}.git"
    export GH_TOKEN="$PROMOTION_TOKEN"
  fi
else
  REMOTE=origin
fi

BRANCH="promote/$FROM-vers-$TO-$(date +%Y%m%d-%H%M)"
git switch -c "$BRANCH"
cp "$SRC" "$DST"
git commit -m "$TITLE" -- "$DST"

if [ "$FORGE" = github ]; then
  git push "$REMOTE" "HEAD:refs/heads/$BRANCH"
  FENCE='```'
  BODY=$(printf 'Versions validées en **%s** (déploiement et tests fonctionnels réussis), copiées vers **%s**.\n\n%sdiff\n%s\n%s\n' \
    "$FROM" "$TO" "$FENCE" "$(git diff HEAD~1 -- "$DST" | tail -n +5)" "$FENCE")
  gh label create promotion --color 0E8A16 --description "Promotion de versions entre environnements" 2>/dev/null || true
  gh pr create --base main --head "$BRANCH" --title "$TITLE" --body "$BODY" --label promotion
else
  # Les options -o font créer la merge request par GitLab au moment du push
  git push "$REMOTE" "HEAD:refs/heads/$BRANCH" \
    -o merge_request.create \
    -o merge_request.target=main \
    -o merge_request.title="$TITLE" \
    -o merge_request.label=promotion \
    -o merge_request.remove_source_branch
fi
