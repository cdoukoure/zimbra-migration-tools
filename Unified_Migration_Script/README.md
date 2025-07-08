
# 📦 Zimbra Migration Tool

**Auteur :** Jean Charles DOUKOURE
**Licence :** GNU GPL v3 + clause de non-responsabilité

## 🛠 Description

Script Bash unifié pour la **migration automatisée** de boîtes mail Zimbra via les services REST. Il prend en charge :

* ✅ Export des comptes `.tgz` via `curl` (API REST)
* ✅ Import des archives `.tgz` via `zmmailbox`
* ✅ Mode `fullsync` (export + import immédiat pour chaque compte)
* ✅ Parallélisation configurable (`xargs -P`)
* ✅ Reprise automatique (skip comptes déjà traités)
* ✅ Suppression automatique des fichiers `.tgz` après import
* ✅ Journaux par utilisateur et par étape
* ✅ Verrou global (`/tmp/zimbra_migration.lock`)

---

## 📌 Dépendances

* `bash`, `curl`, `grep`, `xargs`, `su`, `zmmailbox`
* Doit être lancé depuis un hôte ayant accès au port `7071` du **serveur Zimbra MTA/Proxy**

---

## ⚙️ Utilisation

### ➤ Aide

```bash
./zimbra_migration.sh -h
```

---

### ➤ Commandes disponibles

#### 🔸 Export

```bash
./zimbra_migration.sh export -z IP_ZIMBRA -a ADMIN -p PASS -o EXPORT_DIR -u USERS [-j JOBS]
```

#### 🔸 Import

```bash
./zimbra_migration.sh import -o EXPORT_DIR [-j JOBS] [--import-only-success]
```

#### 🔸 FullSync (export + import immédiat)

```bash
./zimbra_migration.sh fullsync -z IP_ZIMBRA -a ADMIN -p PASS -o EXPORT_DIR -u USERS [-j JOBS]
```

---

## 📥 Paramètres

| Option                  | Description                                                       |
| ----------------------- | ----------------------------------------------------------------- |
| `-z`                    | IP ou FQDN du serveur Zimbra MTA/Proxy                            |
| `-a`                    | Compte admin Zimbra (`admin@domain.com`)                          |
| `-p`                    | Mot de passe du compte admin                                      |
| `-o`                    | Répertoire local pour stocker les archives (`.tgz`) et logs       |
| `-u`                    | Fichier contenant la liste des utilisateurs                       |
| `-j`                    | Nombre de jobs parallèles (défaut: `10`)                          |
| `--import-only-success` | Utilisé pour importer uniquement les comptes exportés avec succès |
| `-h`                    | Affiche l’aide                                                    |

---

## 💡 Bonnes pratiques

* ✅ Lance le script avec `nohup` pour les longues sessions :

  ```bash
  nohup ./zimbra_migration.sh fullsync -z 192.168.10.15 -a admin@domain.com -p monmdp -o /data/zimbra -u users.txt -j 15 > migration.log 2>&1 &
  ```

* ✅ Vérifie l’espace disque : chaque export peut faire jusqu’à 20+ Go

* ✅ Le script crée automatiquement :

  * `success_list.txt`, `failed_list.txt`
  * `import_success.txt`, `import_failed.txt`
  * Un dossier `logs/` avec un `.log` par utilisateur

* ✅ Un verrou `/tmp/zimbra_migration.lock` évite les conflits d'exécution multiples

---

## 🔁 Reprise automatique

Les exports/imports déjà complétés sont **ignorés** à la relance.

---

## 🧹 Nettoyage automatique

Après chaque import réussi, le fichier `.tgz` est **supprimé** du disque pour économiser l’espace.

---

## 📜 Licence

```text
Zimbra Migration Tool
Copyright (c) 2025 Jean Charles DOUKOURE

Ce logiciel est distribué selon les termes de la GNU General Public License v3.

AUCUNE GARANTIE n’est donnée sur le bon fonctionnement de ce script. 
L’utilisateur l’exécute en toute connaissance de cause et sous sa seule responsabilité.
```

