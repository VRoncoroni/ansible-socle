#!/bin/sh
# Lab local du socle : Nexus + trois VM Rocky Linux 9 en conteneurs systemd.
#
#   lab/lab.sh up                         démarre Nexus et les VM
#   lab/lab.sh bootstrap                  dépôts, comptes et clé GPG dans Nexus ; JDK dans raw-outils
#   lab/lab.sh build [VERSION-]BUILD [JAVA]  construit monappli-api (../monappli-api), signe le RPM,
#                                         le publie dans yum-candidates (VERSION : celle du pom par défaut,
#                                         JAVA : release Java visée, celle du pom par défaut)
#   lab/lab.sh seed                       publie les versions des trois versions.yml (celle de la prod en release)
#   lab/lab.sh release VERSION-BUILD      copie un candidat dans yum-releases (même fichier)
#   lab/lab.sh run ENV PLAYBOOK [ARGS]    ansible-playbook sur la VM de ENV (integration|preprod|prod)
#   lab/lab.sh down                       détruit le lab (volumes compris)
#
# Comptes et mots de passe de DÉMONSTRATION uniquement.
set -eu
cd "$(dirname "$0")/.."

NEXUS=${NEXUS:-http://localhost:8081}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin123}
APP_DIR=${APP_DIR:-../monappli-api}
KEYS=lab/.keys
CACHE=lab/.cache
GPG_PASSPHRASE=lab
COMPOSE="docker compose -f lab/compose.yml"

api() {  # api METHODE CHEMIN [JSON]
  curl -fsS -o /dev/null -u "admin:$ADMIN_PASSWORD" -X "$1" -H 'Content-Type: application/json' \
    ${3:+--data "$3"} "$NEXUS/service/rest$2"
}

wait_nexus() {
  printf 'Attente de Nexus'
  until curl -fs -o /dev/null "$NEXUS/service/rest/v1/status/writable"; do printf '.'; sleep 5; done
  echo ' prêt.'
}

repo_yum() {
  api POST /v1/repositories/yum/hosted "{\"name\":\"$1\",\"online\":true,
    \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true,\"writePolicy\":\"allow_once\"},
    \"yum\":{\"repodataDepth\":0,\"deployPolicy\":\"STRICT\"}}" || echo "  $1 existe déjà"
}

repo_raw() {
  api POST /v1/repositories/raw/hosted "{\"name\":\"$1\",\"online\":true,
    \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":false,\"writePolicy\":\"allow_once\"}}" \
    || echo "  $1 existe déjà"
}

role() {  # role ID PRIVILEGE...
  id=$1; shift
  privs=$(printf '"%s",' "$@"); privs=${privs%,}
  api POST /v1/security/roles "{\"id\":\"$id\",\"name\":\"$id\",\"description\":\"lab\",\"privileges\":[$privs],\"roles\":[]}" \
    || echo "  rôle $id existe déjà"
}

user() {  # user ID MOT_DE_PASSE ROLE
  api POST /v1/security/users "{\"userId\":\"$1\",\"firstName\":\"$1\",\"lastName\":\"lab\",
    \"emailAddress\":\"$1@exemple.local\",\"password\":\"$2\",\"status\":\"active\",\"roles\":[\"$3\"]}" \
    || echo "  compte $1 existe déjà"
}

read_privs() {  # privilèges de lecture sur une liste de dépôts « format:nom »
  for r in "$@"; do
    printf 'nx-repository-view-%s-%s-read nx-repository-view-%s-%s-browse ' "${r%%:*}" "${r#*:}" "${r%%:*}" "${r#*:}"
  done
}

upload() {  # upload UTILISATEUR:MDP FICHIER DEPOT/CHEMIN
  curl -fsS -u "$1" --upload-file "$2" "$NEXUS/repository/$3"
}

jdk() {  # jdk VERSION URL_ADOPTIUM
  f="$CACHE/jdk-$1-linux-x64.tar.gz"
  [ -f "$f" ] || curl -fsSL --create-dirs -o "$f" "$2"
  upload "admin:$ADMIN_PASSWORD" "$f" "raw-outils/jdk/jdk-$1-linux-x64.tar.gz" || echo "  JDK $1 déjà présent"
}

case "${1:-}" in
  up)
    $COMPOSE up -d
    # Une VM réelle a diffutils (jeux d'essai) ; l'image de conteneur ne l'a pas forcément
    for vm in vm-int-01 vm-pre-01 vm-prod-01; do
      docker exec "$vm" sh -c 'command -v diff >/dev/null || dnf -q -y install diffutils' \
        || echo "  $vm : installer diffutils à la main"
    done
    wait_nexus
    ;;

  bootstrap)
    wait_nexus
    if docker exec lab-nexus test -f /nexus-data/admin.password; then
      initial=$(docker exec lab-nexus cat /nexus-data/admin.password)
      curl -fsS -u "admin:$initial" -X PUT -H 'Content-Type: text/plain' --data "$ADMIN_PASSWORD" \
        "$NEXUS/service/rest/v1/security/users/admin/change-password"
      api PUT /v1/security/anonymous '{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}'
    fi

    echo "Dépôts"
    repo_yum yum-candidates
    repo_yum yum-releases
    repo_raw raw-outils
    repo_raw raw-apps

    echo "Rôles et comptes"
    # shellcheck disable=SC2046
    {
      role ci-candidates nx-repository-view-yum-yum-candidates-add nx-repository-view-yum-yum-candidates-edit \
        $(read_privs yum:yum-candidates)
      role release nx-repository-view-yum-yum-releases-add nx-repository-view-yum-yum-releases-edit \
        $(read_privs yum:yum-candidates yum:yum-releases)
      role ansible-hors-prod $(read_privs yum:yum-candidates yum:yum-releases raw:raw-outils raw:raw-apps)
      role ansible-prod $(read_privs yum:yum-releases raw:raw-outils raw:raw-apps)
    }
    user svc-ci-monappli ci-lab ci-candidates
    user svc-release release-lab release
    # Mots de passe identiques aux vault.yml de démonstration
    user svc-ansible-int changeme-nexus-integration ansible-hors-prod
    user svc-ansible-pre changeme-nexus-preprod ansible-hors-prod
    user svc-ansible-prod changeme-nexus-prod ansible-prod

    echo "Clé GPG de signature des RPM"
    if [ ! -f "$KEYS/RPM-GPG-KEY-apps" ]; then
      mkdir -p "$KEYS/gnupg" && chmod 700 "$KEYS/gnupg"
      gpg --homedir "$KEYS/gnupg" --batch --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
        --quick-gen-key "monappli lab <lab@exemple.local>" rsa3072 sign never
      gpg --homedir "$KEYS/gnupg" --armor --export > "$KEYS/RPM-GPG-KEY-apps"
      gpg --homedir "$KEYS/gnupg" --batch --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
        --armor --export-secret-keys > "$KEYS/rpm-signing.key"
    fi
    upload "admin:$ADMIN_PASSWORD" "$KEYS/RPM-GPG-KEY-apps" raw-outils/gpg/RPM-GPG-KEY-apps || echo "  clé déjà publiée"

    echo "JDK (Temurin) dans raw-outils"
    jdk 21.0.5+11 "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz"
    jdk 17.0.13+11 "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz"
    echo "Lab prêt : $NEXUS (admin / $ADMIN_PASSWORD)"
    ;;

  build)
    # Reproduit les jobs build, package et publish:candidate du repo de l'application.
    # Une VERSION différente de celle du pom (ancienne version des versions.yml) est construite
    # dans une copie du repo dont le pom est modifié : réservé au lab.
    ARG=${2:-$(date +%H%M)}
    JAVA_RELEASE=${3:-}
    BUILD=${ARG##*-}
    SRC=$APP_DIR
    POM_VERSION=$(cd "$APP_DIR" && mvn -B -q help:evaluate -Dexpression=project.version -DforceStdout)
    VERSION=$POM_VERSION
    case "$ARG" in *-*) VERSION=${ARG%-*} ;; esac
    if [ "$VERSION" != "$POM_VERSION" ]; then
      SRC=$(mktemp -d)
      (cd "$APP_DIR" && git ls-files -z | xargs -0 cp --parents -t "$SRC")
      sed -i "0,/<version>$POM_VERSION<\/version>/s//<version>$VERSION<\/version>/" "$SRC/pom.xml"
    fi
    ROOT=$PWD
    (
      cd "$SRC"
      mvn -B -q -Dbuild.number="$BUILD" ${JAVA_RELEASE:+-Dmaven.compiler.release=$JAVA_RELEASE} verify
      tests/run-cases.sh
      RPM_FILE="monappli-api-$VERSION-$BUILD.noarch.rpm"
      mkdir -p dist
      VERSION=$VERSION BUILD=$BUILD RPM_SIGNING_KEY="$ROOT/$KEYS/rpm-signing.key" NFPM_RPM_PASSPHRASE=$GPG_PASSPHRASE \
        nfpm package --config packaging/nfpm.yaml --packager rpm --target "dist/$RPM_FILE"
      (cd dist && sha256sum "$RPM_FILE" > "$RPM_FILE.sha256")
      mkdir -p "$ROOT/$CACHE/dist" && cp "dist/$RPM_FILE" "dist/$RPM_FILE.sha256" "$ROOT/$CACHE/dist/"
      curl -fsS -u svc-ci-monappli:ci-lab --upload-file "dist/$RPM_FILE" \
        "$NEXUS/repository/yum-candidates/monappli-api/$RPM_FILE"
      echo "Candidat publié : monappli-api $VERSION-$BUILD"
    )
    [ "$SRC" = "$APP_DIR" ] || rm -rf "$SRC"
    ;;

  seed)
    # Les versions des trois versions.yml existent dans Nexus ; celle de la prod est en release.
    # Chaque version est compilée pour le Java de son environnement (2.4.0 et 2.3.7 : Java 17).
    for env in integration preprod prod; do
      VERSIONS="inventories/$env/group_vars/all/versions.yml"
      NEW=$(yq -r '.app_packages[] | select(.name == "monappli-api") | .version' "$VERSIONS")
      JAVA=$(yq -r '.java_version' "$VERSIONS" | cut -d. -f1)
      curl -fs -o /dev/null -u svc-release:release-lab \
        "$NEXUS/repository/yum-candidates/monappli-api/monappli-api-$NEW.noarch.rpm" || "$0" build "$NEW" "$JAVA"
      [ "$env" = prod ] && { "$0" release "$NEW" || echo "  $NEW déjà en release"; }
    done
    ;;

  release)
    # Reproduit le job release : même fichier, contrôlé par son empreinte, copié dans yum-releases
    NEW=${2:?usage : lab/lab.sh release VERSION-BUILD}
    RPM_FILE="monappli-api-$NEW.noarch.rpm"
    tmp=$(mktemp -d)
    curl -fsS -u svc-release:release-lab -o "$tmp/$RPM_FILE" "$NEXUS/repository/yum-candidates/monappli-api/$RPM_FILE"
    if [ -f "$CACHE/dist/$RPM_FILE.sha256" ]; then (cd "$tmp" && sha256sum -c "$OLDPWD/$CACHE/dist/$RPM_FILE.sha256"); fi
    curl -fsS -u svc-release:release-lab --upload-file "$tmp/$RPM_FILE" "$NEXUS/repository/yum-releases/monappli-api/$RPM_FILE"
    rm -rf "$tmp"
    # Nexus régénère les métadonnées yum quelques secondes après l'envoi
    printf 'Release publiée : %s ; attente des métadonnées yum' "$RPM_FILE"
    for _ in $(seq 1 24); do
      primary=$(curl -fsS -u svc-release:release-lab "$NEXUS/repository/yum-releases/repodata/repomd.xml" \
        | grep -o 'repodata/[^"]*primary.xml.gz' | head -1)
      curl -fsS -u svc-release:release-lab "$NEXUS/repository/yum-releases/$primary" | gunzip \
        | grep -q "ver=\"${NEW%-*}\" rel=\"${NEW##*-}\"" && { echo ' : prêt.'; exit 0; }
      printf '.'; sleep 5
    done
    echo ' : délai dépassé (réessayer le déploiement dans une minute).'

    ;;

  run)
    ENV=${2:?usage : lab/lab.sh run ENV PLAYBOOK [ARGS]}
    PLAYBOOK=${3:?usage : lab/lab.sh run ENV PLAYBOOK [ARGS]}
    shift 3
    LAB_ENV=$ENV ansible-playbook -i "inventories/$ENV" -i lab/inventory.yml "playbooks/$PLAYBOOK" \
      --vault-password-file lab/vault-pass.sh --diff "$@"
    ;;

  down)
    $COMPOSE down -v
    ;;

  *)
    sed -n '2,15p' "$0"; exit 2
    ;;
esac
