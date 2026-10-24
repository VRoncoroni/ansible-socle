#!/bin/sh
# Refuse une MR/PR qui mettrait en prod un paquet absent de yum-releases.
# Convention : RPM noarch rangés sous <nom>/ dans le dépôt.
# NEXUS_READ_USER est un compte en lecture seule, utilisable dans les pipelines de MR.
set -eu
FILE=inventories/prod/group_vars/all/versions.yml
fail=0
yq -r '.app_packages[] | .name + " " + .version' "$FILE" > pkgs.txt
while read -r name version; do
  rpm="$name-$version.noarch.rpm"
  if curl -fsSI -o /dev/null -u "$NEXUS_READ_USER:$NEXUS_READ_PASSWORD" \
       "$NEXUS_URL/repository/yum-releases/$name/$rpm"; then
    echo "OK      $rpm"
  else
    echo "ABSENT  $rpm : publiez la release avant de promouvoir en prod"
    fail=1
  fi
done < pkgs.txt
rm -f pkgs.txt
exit "$fail"
