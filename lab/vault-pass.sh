#!/bin/sh
# Mots de passe vault de DÉMONSTRATION (integration-demo, preprod-demo, prod-demo).
# Avant tout usage réel : ansible-vault rekey + nouveaux secrets, et ce fichier disparaît.
printf '%s-demo\n' "${LAB_ENV:?LAB_ENV non défini}"
