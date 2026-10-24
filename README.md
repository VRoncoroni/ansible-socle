# ansible-socle

Provisionner trois VM avec Ansible, de l'intégration à la prod : un seul code, trois inventaires,
des versions de paquets écrites dans Git et une promotion contrôlée d'un environnement à l'autre.

Ce repo est le pendant « déploiement » de [monappli-api](https://github.com/VRoncoroni/monappli-api),
qui construit l'application, la publie dans Nexus (candidat) puis la promeut en release.

```
monappli-api  ──merge──▶ build + tests ──▶ RPM signé ──▶ yum-candidates ──▶ PR « candidat » ici
                                                                              │
ansible-socle  intégration (auto) ──tests──▶ PR promotion ──▶ preprod (approbation) ──tests──▶ PR promotion
                                                                              │
monappli-api   release (manuel) : même RPM copié dans yum-releases, tag vX.Y.Z
                                                                              │
ansible-socle  check-prod-releases ✔ ──▶ prod (approbation) ──▶ contrôle de santé + preuve de version
```

## Sommaire

1. [Le principe](#1-le-principe)
2. [Structure du repo](#2-structure-du-repo)
3. [Démarrage rapide](#3-démarrage-rapide)
4. [Inventaires et versions](#4-inventaires-et-versions)
5. [Les rôles et les playbooks](#5-les-rôles-et-les-playbooks)
6. [Java](#6-java)
7. [Secrets](#7-secrets)
8. [Tests](#8-tests)
9. [Pipelines CI/CD](#9-pipelines-cicd)
10. [Parcours d'une version](#10-parcours-dune-version)
11. [Où placer le runner](#11-où-placer-le-runner)
12. [Mises à jour](#12-mises-à-jour)
13. [Rollback](#13-rollback)
14. [Le lab local](#14-le-lab-local)
15. [Pièges et checklist](#15-pièges-et-checklist)
16. [Écarts avec le guide d'origine](#16-écarts-avec-le-guide-dorigine)

## 1. Le principe

| Règle | Concrètement |
|---|---|
| **Un code, trois inventaires** | Les rôles sont identiques pour les trois VM. Seules les variables changent, rangées par environnement. |
| **Les versions sont des données** | Chaque environnement a son `versions.yml` avec des versions exactes. Jamais de `latest`. |
| **On promeut, on ne réécrit pas** | Une version validée en intégration est copiée vers la preprod, puis vers la prod, chaque fois par une MR/PR distincte. |
| **Git décrit la réalité** | Ce qui est dans `main` pour un environnement est ce qui tourne sur sa VM. La détection de dérive le vérifie chaque matin. |

## 2. Structure du repo

```
ansible-socle/
├── ansible.cfg                    # inventaire par défaut : intégration, jamais la prod
├── requirements.yml               # collections Ansible, versions exactes
├── requirements-dev.txt           # ansible-core, ansible-lint, yamllint, molecule (figés)
├── .gitlab-ci.yml                 # pipeline GitLab
├── .github/workflows/             # variante GitHub Actions : ci, _deploy, drift, patch-os
├── inventories/
│   ├── integration/
│   │   ├── hosts.yml              # la VM d'intégration
│   │   ├── known_hosts            # clés SSH attendues
│   │   └── group_vars/all/
│   │       ├── main.yml           # paramètres propres à l'env (URLs, niveaux de log…)
│   │       ├── versions.yml       # versions des paquets et du JDK pour cet env
│   │       └── vault.yml          # secrets chiffrés avec ansible-vault
│   ├── preprod/                   # même structure
│   └── prod/                      # même structure
├── playbooks/
│   ├── group_vars/all.yml         # variables dérivées communes (java_home)
│   ├── site.yml                   # déploiement, avec retour arrière automatique
│   ├── test-functional.yml        # rejoue les jeux d'essai sur la VM
│   ├── tasks/run-case.yml         # un cas de test
│   └── patch-os.yml               # mises à jour système, hors paquets applicatifs
├── roles/
│   ├── nexus_repo/                # clé GPG + dépôts yum Nexus (candidates / releases)
│   ├── java/                      # JDK versionné depuis Nexus, purge des anciens
│   ├── app_packages/              # RPM aux versions exactes ; archives tar.gz (raw.yml)
│   └── app_config/                # configuration, secrets, api.env, JAVA_HOME, service
│       └── molecule/default/      # converge + idempotence + verify dans Rocky 9 systemd
├── tests/functional/              # cas-01-nominal, cas-02-fichier-vide, cas-03-accents-latin1
├── scripts/
│   ├── vault-pass.sh              # lit le mot de passe vault depuis la CI
│   ├── promote.sh                 # copie les versions vers l'env suivant et ouvre la MR/PR
│   └── check-prod-releases.sh     # refuse une prod qui contiendrait un candidat
├── ci/ansible-ci.Dockerfile       # image d'outillage des jobs GitLab
├── lab/                           # Nexus + 3 VM en conteneurs pour tout jouer en local
├── .ansible-lint · .yamllint
└── CODEOWNERS
```

`versions.yml` est isolé pour être **le seul fichier à toucher** lors d'une montée de version :
une promotion se réduit à copier ce fichier d'un environnement au suivant, et la revue tient en
quelques lignes.

## 3. Démarrage rapide

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
ansible-galaxy collection install -r requirements.yml      # dans ./collections

yamllint . && ansible-lint                                   # statique (profil production)
(cd roles/app_config && molecule test)                       # rôle isolé + idempotence

# voir ce qui changerait, sans rien modifier
ansible-playbook -i inventories/integration playbooks/site.yml --check --diff --ask-vault-pass
# appliquer
ansible-playbook -i inventories/integration playbooks/site.yml --diff --ask-vault-pass
# ne rejouer que la configuration
ansible-playbook -i inventories/preprod playbooks/site.yml --tags config --diff --ask-vault-pass
# jeux d'essai sur la VM
ansible-playbook -i inventories/integration playbooks/test-functional.yml --ask-vault-pass
```

Sans infrastructure : [le lab local](#14-le-lab-local) joue tout le parcours sur votre poste.

## 4. Inventaires et versions

Chaque environnement est un dossier d'inventaire autonome ; on cible un environnement avec
`-i inventories/<env>`, rien d'autre. Les valeurs communes vivent dans `roles/*/defaults/`, les
`group_vars` de l'inventaire les surchargent.

| Élément | integration | preprod | prod |
|---|---|---|---|
| VM | vm-int-01 (10.10.1.11) | vm-pre-01 (10.10.2.11) | vm-prod-01 (10.10.3.11) |
| Dépôts Nexus | yum-candidates, yum-releases | yum-candidates, yum-releases | **yum-releases seul** |
| Log | debug | info | warn |
| `java_version` | 21.0.5+11 | 17.0.13+11 | 17.0.13+11 |
| `monappli-api` | 2.4.1-38 | 2.4.0-31 | 2.3.7-22 |

L'intégration a une version d'avance ; une migration Java 17 → 21 y est en cours de validation
(`java_keep` y garde le 17 pour un retour arrière rapide).

Les versions applicatives sont au format **version-build** (`2.4.1-38` = version du code `2.4.1`,
build `38`), qui est le couple `Version-Release` du RPM.

`monappli-worker` et `outil-batch` sont en commentaire dans les `versions.yml` : ce sont des exemples
de paquets supplémentaires à activer quand ils existent dans Nexus. Les artefacts qui ne sont pas
des paquets (tar.gz du dépôt `raw-apps`) se déclarent dans `app_archives`.

## 5. Les rôles et les playbooks

Quatre rôles courts, appelés dans cet ordre par `site.yml` :

| Rôle | Responsabilité |
|---|---|
| `nexus_repo` | Télécharge et importe la clé GPG des RPM, déclare les dépôts de `nexus_yum_repos` et **retire les autres** (un ajout manuel ne survit pas au passage suivant). Fichier `.repo` en `0600` : il contient le mot de passe. |
| `java` | Télécharge l'archive du JDK depuis `raw-outils` avec contrôle sha256, l'extrait dans `/opt/java/jdk-<version>`, vérifie `java -version`, purge les JDK (et archives) ni courants ni dans `java_keep`. |
| `app_packages` | `dnf` à la version exacte avec `allow_downgrade` (le retour arrière = changer la version). `raw.yml` : une archive tar.gz par version, un lien `current`, trois releases gardées. |
| `app_config` | `app.conf` (validé par `monappli --check-config` avant écriture, sauvegarde `.backup`), `secrets.conf` (sans diff ni log), `api.env`, surcharge systemd `java.conf` (JAVA_HOME), service activé et démarré. |

Tous les rôles notifient le sujet `app_restart` : l'application ne redémarre **qu'une fois**, et
seulement s'il y a eu un changement.

`site.yml` ajoute :

- **le retour arrière automatique** : les versions en place sont relevées avant le déploiement ; si un
  rôle, le contrôle de santé (`/health`) ou la preuve de version échoue, elles sont réinstallées, le
  service redémarre dessus, puis le job échoue quand même ;
- **la preuve de version** : `/version` doit annoncer exactement la version de `versions.yml`.

## 6. Java

Le JDK se traite comme n'importe quel paquet : sa version est écrite dans `versions.yml` et suit la
même promotion. L'archive Temurin est déposée dans le dépôt raw `raw-outils` de Nexus
(`jdk/jdk-21.0.5+11-linux-x64.tar.gz`) : la version testée en intégration est exactement celle qui
arrive en prod.

- Le **JAVA_HOME** se fixe par application, dans sa unit systemd (`/etc/systemd/system/monappli-api.service.d/java.conf`).
  Ni `/etc/profile.d/` (non lu par systemd), ni `alternatives` (changerait le java de toute la machine).
- Plusieurs applications avec des besoins différents : une variable chacune (`api_java_version`,
  `batch_java_version`) ; les JDK cohabitent dans `/opt/java`.

**Changer de version de Java**

1. Déposer la nouvelle archive dans `raw-outils/jdk/` et noter son empreinte sha256.
2. Dans le `versions.yml` de l'intégration : `java_version`, `java_sha256`, et l'ancienne version dans `java_keep`.
3. Au déploiement : nouveau JDK extrait à côté de l'ancien, surcharge systemd modifiée, un seul redémarrage.
   Les jeux d'essai tournent avec ce JDK.
4. Promotion vers preprod puis prod comme un paquet.
5. Prod stable : retirer l'ancienne version de `java_keep`, elle est purgée au passage suivant.

Si une version de l'application exige une version de Java, modifiez les deux **dans le même commit**.
Le lab l'illustre : un jar compilé pour Java 21 refuse de démarrer sur un JDK 17
(`UnsupportedClassVersionError`), le contrôle `--check-config` échoue et le playbook remet la version
précédente.

## 7. Secrets

Un `vault.yml` chiffré par environnement, avec **un mot de passe vault différent par environnement**.
La convention `vault_` garde `main.yml` lisible en clair : on y voit quelle variable existe, la valeur
reste chiffrée.

```sh
ansible-vault edit inventories/prod/group_vars/all/vault.yml
```

> ⚠️ Les `vault.yml` livrés sont des **valeurs de démonstration** chiffrées avec `integration-demo`,
> `preprod-demo` et `prod-demo` (utilisés par le lab). Avant tout usage réel :
> `ansible-vault rekey inventories/<env>/group_vars/all/vault.yml`, puis remplacez les valeurs.

En CI, le mot de passe vient d'une variable lue par `scripts/vault-pass.sh`.

**GitLab** (Settings › CI/CD › Variables)

| Variable | Type | Portée | Options |
|---|---|---|---|
| `ANSIBLE_VAULT_PASSWORD` | Variable | créée 3 fois : integration, preprod, prod | Masquée ; protégée pour preprod et prod |
| `SSH_PRIVATE_KEY` | Fichier | 3 fois, une clé par env | Protégée pour preprod et prod. Inutile si le runner est sur la VM. |
| `PROMOTION_TOKEN` | Variable | toutes | Masquée, protégée. Jeton d'accès projet, rôle Developer, `write_repository`. |
| `NEXUS_URL`, `NEXUS_READ_USER`, `NEXUS_READ_PASSWORD` | Variable | toutes | Compte Nexus **lecture seule**, non protégé (utilisé dans les MR par `check:prod-releases`). |

**GitHub** (Settings › Environments, Settings › Secrets and variables › Actions)

| Où | Nom | Contenu |
|---|---|---|
| Environnements `integration`, `preprod-plan`, `preprod`, `prod-plan`, `prod` | secrets `ANSIBLE_VAULT_PASSWORD`, `SSH_PRIVATE_KEY` | ceux de l'environnement (`preprod-plan` = mêmes valeurs que `preprod`) |
| Repo | secret `PROMOTION_TOKEN` | PAT fine-grained (ou jeton de GitHub App) : *Contents* et *Pull requests* en écriture. Une PR ouverte avec le `GITHUB_TOKEN` ne déclencherait pas la CI. |
| Repo | secrets `NEXUS_READ_USER`, `NEXUS_READ_PASSWORD` | compte Nexus lecture seule |
| Repo | variable `NEXUS_URL` | `https://nexus.exemple.local` |
| Repo | variable `DEPLOY_ENABLED` | `true` dès que les runners auto-hébergés `ansible-<env>` existent ; sans elle, seules les vérifications tournent (pas de job bloqué en attente d'un runner). |

Côté Nexus, un compte en lecture seule par environnement (`svc-ansible-int`, `-pre`, `-prod`),
limité aux dépôts nécessaires (la prod ne lit pas `yum-candidates`).

## 8. Tests

| Niveau | Outil | Ce que ça attrape | Quand |
|---|---|---|---|
| Statique | `yamllint`, `ansible-lint` (profil production) | syntaxe, modules non qualifiés, `latest` oublié | chaque MR/PR |
| Rôle isolé | `molecule test` (Rocky 9 + systemd) | rôle qui plante, **rôle non idempotent** | chaque MR/PR |
| Plan | `--check --diff` | l'écart exact entre le repo et la VM | avant chaque déploiement |
| Fonctionnel | jeux d'essai `tests/functional/` | mauvais Java, droits, encodage, version du paquet | après chaque déploiement en intégration et preprod |

Chaque cas est un dossier `input/` + `expected/`, comparé **octet pour octet** avec `diff -ru` à la
sortie de `/opt/monappli/bin/generer-synthese` (livré par le RPM monappli-api), exécuté sous le compte
`monappli` avec la date de référence figée `2026-01-01`. Tous les cas sont joués même si l'un échoue,
puis le bilan liste les cas en échec avec leur diff.

- La logique du générateur est testée dans le repo de l'application (`tests/cases/`, plus de cas) ;
  ici, une poignée de cas représentatifs testent **l'installation**.
- Pas de données réelles dans Git : jeux d'essai fabriqués ou anonymisés.
- `.gitattributes` empêche toute conversion de fins de ligne ou d'encodage (`cas-03` est en ISO-8859-1).
- Prérequis sur la VM : `acl` (devenir `monappli` depuis `deploy`, dépendance du RPM) et `diffutils`.

## 9. Pipelines CI/CD

### GitLab (`.gitlab-ci.yml`)

```
Merge request    lint · molecule · check:prod-releases* ─▶ plan:integration (--check --diff)
                                                    * seulement si le versions.yml de prod change
Pipeline main    deploy:integration ─▶ test:integration ─▶ propose:preprod
   (seuls les    plan:preprod ─▶ deploy:preprod (manuel) ─▶ test:preprod ─▶ propose:prod
    envs touchés) plan:prod ─▶ deploy:prod (manuel)
Planifié         drift (SCHEDULE_TASK=drift) · patch-os (SCHEDULE_TASK=patch-os, PATCH_TARGET=<env>)
```

- Chaque bloc du pipeline sur `main` n'existe que si le commit concerne cet environnement : une MR
  de promotion vers la prod ne produit que `plan:prod` et `deploy:prod`.
- `needs` optionnels : `plan:preprod` attend les tests d'intégration s'ils existent dans ce pipeline.
- Manuel bloquant (`when: manual` + `allow_failure: false`) : le pipeline s'affiche « bloqué ».
- `environment: action: prepare / verify` : plans et tests reçoivent les variables de l'environnement
  sans compter comme des déploiements. `resource_group` : un déploiement à la fois par environnement.
- `ansible.log` reste 30 jours en artefact ; les secrets n'y figurent pas (`no_log`, `diff: false`).

Réglages : `main` protégée (fusion par les mainteneurs, « le pipeline doit réussir »), approbation des
CODEOWNERS, variables protégées pour preprod/prod, *Prevent outdated deployment jobs* (en gardant
*Allow job retries for rollback deployments*), *Deploy freezes*, planification quotidienne
`SCHEDULE_TASK=drift`. En Premium : environnements protégés et approbations de déploiement.

### GitHub Actions (`.github/workflows/`)

| Workflow | Rôle |
|---|---|
| `ci.yml` | PR : `lint`, `molecule`, `check-prod-releases`, `plan-integration`. Push sur `main` : le job `changes` calcule les environnements concernés, puis deploy → test → propose, preprod et prod derrière l'approbation des environnements `preprod` et `prod`. |
| `_deploy.yml` | Workflow réutilisable : un passage Ansible (`apply` ou `check`) sur un runner `[self-hosted, ansible-<env>]`, log en artefact. |
| `drift.yml` | Détection de dérive en semaine à 5 h 17 UTC (et à la demande). |
| `patch-os.yml` | Patchs système, à la demande, par environnement. |

Côté GitHub, l'approbation se donne **avant** que le job démarre : les plans et tests utilisent les
environnements `preprod-plan` / `prod-plan` (limités à `main`, sans reviewers), les déploiements
`preprod` / `prod` (reviewers requis). Règle de branche sur `main` : PR obligatoire, revue des
CODEOWNERS, contrôles requis `lint`, `molecule`, `check-prod-releases`, `plan-integration`.
Activez *Allow auto-merge* pour que les PR « candidat » fusionnent seules quand le plan passe.

## 10. Parcours d'une version

Exemple : passage de monappli-api de 2.4.0-31 à 2.4.1-38.

1. **MR/PR d'intégration** — ouverte par le pipeline de monappli-api (branche
   `maj/monappli-api-2.4.1-38`, une ligne dans `inventories/integration/…/versions.yml`). Le pipeline
   lance le lint, Molecule et le plan d'intégration, dont le log montre `2.4.0-31 → 2.4.1-38`.
   Rien n'est modifié sur la VM.
2. **Merge : intégration** — déploiement automatique, jeux d'essai, preuve de version ; si tout passe,
   `propose:preprod` ouvre « Promotion des versions : integration vers preprod ».
3. **Merge de la promotion preprod** — plan preprod, déploiement après clic/approbation, jeux d'essai,
   puis `propose:prod` ouvre la promotion suivante.
4. **Release** — dans monappli-api, le job `release` vérifie que la preprod tourne en 2.4.1-38, copie
   le même RPM dans `yum-releases` et crée le tag `v2.4.1`.
5. **Merge de la promotion prod** — `check:prod-releases` refuse la fusion tant que la release
   n'existe pas ; relancez-le après la release. Plan prod, déploiement après approbation, contrôle de
   santé et preuve de version.

Résultat : trois commits dans `main`, chacun relié à un déploiement.
`git log inventories/prod/group_vars/all/versions.yml` est le journal des mises en production.

| Pipeline | integration | preprod | prod |
|---|---|---|---|
| MR de mise à jour | plan | — | — |
| main, après la MR de mise à jour | deploy, test, propose | — | — |
| main, après la promotion preprod | — | plan, deploy (manuel), test, propose | — |
| main, après la promotion prod | — | — | plan, deploy (manuel) |
| main, changement d'un rôle ou d'un template | deploy, test | plan, deploy (manuel), test | plan, deploy (manuel) |

```sh
scripts/promote.sh integration preprod   # à la main : même chose que propose:preprod (MR GitLab ou PR GitHub)
```

- **Pourquoi pas une seule MR qui modifie les trois fichiers ?** Si l'intégration échoue, `main`
  contiendrait des versions qui ne tournent nulle part. Exception : le **correctif urgent**, où une MR
  unique traverse les trois environnements (preprod et prod restent manuels).
- **Pas de plan preprod ou prod dans les MR** : leurs secrets sont protégés, réservés à `main`.
- **Pipelines lancés à la main ou planifiés** : tous les environnements sont concernés, preprod et prod
  restent manuels.

## 11. Où placer le runner

| Option | Connexion | Points forts | Limites |
|---|---|---|---|
| A. Runner bastion unique | SSH vers les 3 VM | aucun outillage CI sur les VM | le bastion détient les clés de la prod |
| **B. Un runner sur chaque VM** | locale | aucune clé SSH ni flux entrant | runner et Ansible présents sur la prod |
| **C. Runner sur l'intégration, bastion pour preprod/prod** | locale + SSH | démarrage rapide, prod sans outillage CI | deux modes de connexion |
| D. Runner d'intégration qui déploie aussi preprod/prod | SSH | une seule installation | **à éviter** : l'environnement le moins protégé détient les clés de la prod |

Runner sur la VM : décommentez la variante `ansible_connection: local` de
`inventories/integration/hosts.yml` (Python système forcé pour les bindings dnf), puis, en root :

```sh
python3 -m venv /opt/ansible
/opt/ansible/bin/pip install -r requirements-dev.txt          # ansible-core figé
dnf install -y gitlab-runner
gitlab-runner register --non-interactive --url https://gitlab.exemple.local \
  --token glrt-xxxxxxxxxxxx --executor shell                   # tag ansible-integration
echo 'gitlab-runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/gitlab-runner && chmod 440 /etc/sudoers.d/gitlab-runner
# /etc/gitlab-runner/config.toml : concurrent = 1 ; environment = ["PATH=/opt/ansible/bin:/usr/local/bin:/usr/bin:/bin"]
```

Côté GitHub : un runner auto-hébergé par VM (ou par bastion) avec le label `ansible-<env>`, ajouté au
seul repo. Précautions : lint et Molecule sur des runners avec Docker (hébergés GitHub ici), runners
preprod/prod protégés (GitLab : « Protected » ; GitHub : environnements limités à `main`), un job ne
survit pas au redémarrage de sa propre VM (`shutdown -r +2`), le runner est exclu des patchs système.

## 12. Mises à jour

| Changement | Fichier à modifier | Chemin |
|---|---|---|
| Nouveau candidat d'une de vos applications | rien : PR ouverte par le pipeline de l'application | merge, intégration, puis PR de promotion automatique |
| Nouvelle version d'un paquet tiers | `inventories/integration/…/versions.yml` | même chemin, PR ouverte à la main |
| Promotion d'une version validée | `versions.yml` de l'env suivant | PR ouverte par `propose`, ou `scripts/promote.sh` |
| Release d'un candidat validé en preprod | rien ici : job `release` de l'application | le paquet passe dans `yum-releases`, la promotion prod peut passer |
| Nouvelle version de Java | `java_version`, `java_sha256`, `java_keep` | comme un paquet ; le JDK précédent reste sur disque |
| Correctif urgent | les trois `versions.yml` dans la même PR | un pipeline, deux déclenchements manuels |
| Template ou rôle commun | `roles/…` | un pipeline qui traverse les trois envs |
| Valeur propre à un env | `inventories/<env>/…/main.yml` | seul l'env concerné a des jobs |
| Rotation d'un secret | `ansible-vault edit …/vault.yml` | comme une valeur propre à un env |
| Nouveau jeu d'essai | `tests/functional/<cas>/` | rejoué en intégration et en preprod |
| Ajout d'une VM | `hosts.yml` + `known_hosts` | le prochain run la provisionne |
| Patchs système | `playbooks/patch-os.yml` | planification séparée, hors dépôts applicatifs |

Une VM vierge se provisionne directement par un déploiement : un `--check` sur une VM qui n'a encore
ni dépôt ni JDK n'a rien à comparer et échoue sur le premier téléchargement.

## 13. Rollback

| Situation | Méthode | Délai |
|---|---|---|
| Le déploiement échoue (rôle, santé, version) | retour automatique aux versions précédentes dans `site.yml` ; le job échoue quand même | immédiat |
| Régression vue après coup | **MR/PR de revert** du commit de promotion | le temps d'un pipeline |
| Régression en prod, urgence | GitLab : redéployer le déploiement précédent (Operate › Environments) ; GitHub : relancer l'ancien run `deploy-prod` ; **puis** la PR de revert le jour même | quelques minutes |

```sh
git revert <sha du commit « Promotion des versions : preprod vers prod »>
# PR, merge : seul le plan prod apparaît (2.4.1-38 → 2.4.0-31), deploy-prod à approuver
```

| Élément | Mécanisme | Condition |
|---|---|---|
| Paquets RPM | `allow_downgrade: true` | l'ancienne version doit encore exister dans Nexus |
| Archives raw | le lien `current` repointe vers la release précédente | trois releases gardées sur disque |
| Configuration | le template de l'ancien commit est réappliqué ; `.backup` sur la VM | — |
| Java | `java_version` revient, la surcharge systemd suit | l'ancien JDK est dans `java_keep`, sinon retéléchargé |
| Secrets | le vault de l'ancien commit est réappliqué | l'ancien secret n'a pas été révoqué |
| Schéma ou données | aucun automatisme | procédure inverse écrite et testée en preprod |

Le retour automatique ne restaure ni la configuration ni le JDK : leur retour complet passe par le revert.

## 14. Le lab local

`lab/` joue tout le parcours sans infrastructure : un Nexus 3 et trois « VM » Rocky Linux 9 avec
systemd en conteneurs (`vm-int-01`, `vm-pre-01`, `vm-prod-01`). Les inventaires du repo sont utilisés
tels quels ; `lab/inventory.yml` les surcharge (connexion Docker, Nexus du réseau compose).

Prérequis : Docker avec compose, `gpg`, `curl`, `yq`, Maven + JDK 21, `nfpm`, et le repo
monappli-api cloné à côté (`../monappli-api`, ou `APP_DIR=…`).

```sh
lab/lab.sh up                               # Nexus (http://localhost:8081) + 3 VM
lab/lab.sh bootstrap                        # dépôts, comptes, clé GPG, JDK 17 et 21 dans raw-outils
lab/lab.sh seed                             # publie 2.4.1-38, 2.4.0-31 (Java 17), 2.3.7-22 (release)

lab/lab.sh run integration site.yml         # déploiement
lab/lab.sh run integration test-functional.yml
lab/lab.sh run preprod site.yml --check     # plan

lab/lab.sh build 39                         # nouveau candidat 2.4.1-39 dans yum-candidates
lab/lab.sh release 2.4.1-39                 # même RPM copié dans yum-releases
lab/lab.sh down                             # tout détruire
```

Scénarios validés avec ce lab : déploiement complet et idempotence (`changed=0` au second passage),
jeux d'essai sur le RPM installé, promotion avec migration Java 17 → 21, refus d'un candidat en prod
(`check-prod-releases.sh` puis `dnf` sans `yum-candidates`) avec **retour automatique** à la version
précédente, release puis déploiement en prod, détection de dérive, revert avec rétrogradation du
paquet et du JDK, archives tar.gz avec bascule de lien et purge.

Comptes du lab (démonstration uniquement) : `admin/admin123`, `svc-ci-monappli/ci-lab`,
`svc-release/release-lab`, `svc-ansible-{int,pre,prod}` avec les mots de passe des `vault.yml` de démonstration.

## 15. Pièges et checklist

- [x] Aucune version `latest` ni plage dans `versions.yml` : versions exactes, JDK compris.
- [x] `no_log: true` sur toute tâche qui manipule un mot de passe, `diff: false` sur les templates qui en contiennent.
- [x] `validate:` sur `app.conf` (vérificateur fourni par l'application).
- [x] `{{ ansible_managed }}` en tête de chaque fichier généré.
- [x] Playbook idempotent (Molecule + lab : `changed=0` au second passage).
- [x] JAVA_HOME fixé dans la unit de l'application, jamais globalement.
- [x] Jeux d'essai déterministes (date de référence, tri stable), sans données réelles.
- [ ] Politiques de nettoyage Nexus qui conservent les versions en prod et la précédente (`yum-candidates` : 90 jours sans téléchargement ; `yum-releases` : aucun).
- [x] Le défaut de `ansible.cfg` pointe vers l'intégration, jamais vers la prod.
- [ ] Un mot de passe vault et une clé SSH distincts par environnement, en variables limitées à leur environnement (à créer, et `rekey` des vaults de démonstration).
- [ ] Runners preprod et prod protégés ; aucun runner d'intégration ne détient de secret de prod.
- [x] Collections épinglées dans `requirements.yml`, `ansible-core` figé dans `requirements-dev.txt`.
- [x] `serial` et `max_fail_percentage` dans `patch-os.yml` ; à ajouter à `site.yml` dès qu'un environnement compte plus d'une VM.
- [ ] Après un redéploiement d'urgence, une MR de revert le jour même.
- [x] La prod ne déclare que `yum-releases` ; un candidat ne peut pas y être installé.
- [ ] « Disable redeploy » (write policy *allow once*) sur les dépôts Nexus.
- [ ] Tags `v*` protégés dans le repo de l'application ; une release ne se crée que par le job release.

Les cases non cochées sont des réglages d'infrastructure (Nexus, forge, runners) à faire une fois.

## 16. Écarts avec le guide d'origine

Le repo suit le guide « Socle Ansible trois environnements » ; les points suivants ont été corrigés
ou complétés en le faisant tourner pour de vrai (lab) :

| Point | Ce qui change, et pourquoi |
|---|---|
| Versions précédentes du retour automatique | `package_facts` sépare `version` (2.4.1) et `release` (38) : on les recolle (`2.4.1-38`), sinon la réinstallation vise un paquet qui n'existe pas. |
| Clé GPG des RPM | téléchargée avec les identifiants Nexus dans `/etc/pki/rpm-gpg/` puis importée (`rpm_key`), au lieu d'une URL `gpgkey` qui suppose un accès anonyme. |
| `force_basic_auth` | sur les `get_url` vers Nexus, qui ne renvoie pas toujours de défi 401. |
| Mode `--check` du rôle java | extraction et `java -version` sautées en plan (l'archive n'est pas téléchargée en check). |
| Purge des archives de JDK | ajoutée : sans elle, `/opt/java/archives` grossit à chaque version. |
| Purge des releases tar.gz | triée par numéro de version (`community.general.version_sort`), pas par date de dossier. |
| Unit systemd | `ExecStart=${JAVA_HOME}/bin/java` n'est pas accepté par systemd (le programme ne peut pas être une variable) : un lanceur `/opt/monappli/bin/monappli-api` lit `JAVA_HOME`. |
| Ouverture de la PR candidat | `yq -i` reformatait tout `versions.yml` ; une substitution ciblée, vérifiée par `yq`, garde une PR d'une ligne. |
| GitHub | jobs `propose-*`, `check-prod-releases`, `drift.yml` et `patch-os.yml` ajoutés à la variante ; vérifications sur runners hébergés, déploiements derrière `DEPLOY_ENABLED`. |
| Nexus | le rôle qui publie les releases a besoin des droits `add` **et** `edit` ; les métadonnées yum sont régénérées quelques secondes après l'envoi. |
