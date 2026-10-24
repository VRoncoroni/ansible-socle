#!/bin/sh
# Lit le mot de passe vault de l'environnement depuis la CI (variable limitée à cet environnement)
printf '%s\n' "$ANSIBLE_VAULT_PASSWORD"
