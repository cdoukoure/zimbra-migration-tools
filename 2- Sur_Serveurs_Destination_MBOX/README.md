Voici un README clair et complet pour ton script d’export massif Zimbra avec reprise et parallélisation.

---

# README - Export massif des boîtes mail Zimbra avec reprise et parallélisation

## Description

Ce script Bash permet d’exporter en masse les boîtes mail Zimbra via l’API REST d’admin, avec :

* Authentification par token (SOAP admin)
* Export au format `.tgz`
* Gestion des plages de dates (début / fin)
* Parallélisation configurable (plusieurs exports simultanés)
* Logs séparés par utilisateur + log global
* Verrou global pour éviter exécution multiple concurrente
* Reprise automatique des exports en cas d’arrêt (ignore comptes déjà exportés)
* Rapport final détaillé avec statistiques et fichiers d’erreurs

---

## Prérequis

* Serveur Zimbra accessible sur le port 7071 (MTA / Proxy)
* Compte administrateur Zimbra avec mot de passe
* `bash`, `curl`, `date`, `grep`, `xargs` installés sur la machine de lancement
* Accès SSH / shell sur la machine de lancement
* Fichier texte listant les comptes à exporter (1 email par ligne, commentaires `#` acceptés)

---

## Installation

1. Copier le script `zimbra_export_massive.sh` sur le serveur ou machine client.
2. Rendre exécutable :

```bash
chmod +x zimbra_export_massive.sh
```

3. Préparer un fichier utilisateur (`users.txt`), par exemple :

```txt
user1@domain.com
user2@domain.com
# user3@domain.com désactivé temporairement
user4@domain.com
```

---

## Usage

```bash
./zimbra_export_massive.sh -z IP_OU_FQDN -a ADMIN_USER -p ADMIN_PASS [options]
```

### Options

| Option | Description                                 | Par défaut                                  | Obligatoire |
| ------ | ------------------------------------------- | ------------------------------------------- | ----------- |
| -z     | IP ou FQDN du serveur Zimbra (proxy/MTA)    | -                                           | Oui         |
| -a     | Compte admin Zimbra                         | [admin@domain.com](mailto:admin@domain.com) | Non         |
| -p     | Mot de passe admin                          | -                                           | Oui         |
| -s     | Date début export (JJ/MM/AAAA)              | Tout début                                  | Non         |
| -e     | Date fin export (JJ/MM/AAAA)                | Demain                                      | Non         |
| -o     | Répertoire local où sauvegarder les exports | /opt/zimbra/backups/remote                  | Non         |
| -u     | Fichier liste des utilisateurs              | /home/ubuntu/users.txt                      | Non         |
| -j     | Nombre de jobs parallèles                   | 10                                          | Non         |
| -h     | Affiche l’aide                              | -                                           | Non         |

---

### Exemple simple

```bash
./zimbra_export_massive.sh -z 192.168.1.10 -a admin@domain.com -p secret -e 15/07/2025
```

---

### Exemple avec parallélisation et dossier custom

```bash
nohup ./zimbra_export_massive.sh -z zimbra.example.com -a admin@example.com -p secretpass -o /data/exports -j 20 > export_$(date +%F_%H%M).log 2>&1 &
```

---

## Fonctionnement

* Le script se connecte en SOAP pour récupérer un token d’authentification.
* Il lit la liste des utilisateurs et exporte chaque boîte mail via une requête REST.
* Il effectue jusqu’à `-j` exports en parallèle pour accélérer le traitement.
* Chaque export est réessayé jusqu’à 3 fois en cas d’erreur.
* Les comptes déjà exportés (succès ou échec) ne sont pas retraités.
* Les logs sont disponibles dans le dossier d’export, avec un log global et un log par utilisateur.
* Un fichier `success_list.txt` et `failed_list.txt` permettent de suivre les comptes traités.
* Un verrou (lock file) empêche plusieurs instances du script de tourner simultanément.

---

## Fichiers générés

* `${EXPORT_DIR}/<user>.tgz` : archive exportée de chaque boîte mail
* `${EXPORT_DIR}/success_list.txt` : liste des comptes exportés avec succès
* `${EXPORT_DIR}/failed_list.txt` : liste des comptes ayant échoué
* `${EXPORT_DIR}/export_YYYYMMDD_HHMMSS.log` : log global de l’exécution
* `${EXPORT_DIR}/logs/<user>.log` : logs détaillés par utilisateur

---

## Reprise automatique

Si le script est interrompu, il peut être relancé sans perdre les progrès.
Il ignore automatiquement les utilisateurs dont les exports sont déjà terminés (succès ou échec).

---

## Conseils

* Adapter la parallélisation selon les ressources disponibles.
* Vérifier l’espace disque disponible dans le dossier d’export.
* Lancer en `nohup` ou `screen` / `tmux` pour les exports longs.
* Sauvegarder régulièrement les fichiers d’export.
* Surveiller les logs pour détecter les erreurs.

---

## Support / Contact


---

## Licence

Ce script est distribué sous la licence **GNU General Public License version 3 (GPL v3)**.

Vous pouvez redistribuer et/ou modifier ce script selon les termes de la licence GPL v3, telle que publiée par la Free Software Foundation :
[https://www.gnu.org/licenses/gpl-3.0.html](https://www.gnu.org/licenses/gpl-3.0.html)

---

## Clause de non-responsabilité

Ce script est fourni **"tel quel"**, sans aucune garantie d’aucune sorte, expresse ou implicite, y compris, mais sans s’y limiter, les garanties de qualité marchande, d’adaptation à un usage particulier, ou d’absence de contrefaçon.

L’utilisateur exécute ce script à ses propres risques. En aucun cas, l’auteur ne pourra être tenu responsable des dommages directs ou indirects, pertes de données, profits ou toute autre perte découlant de l’utilisation ou de l’impossibilité d’utiliser ce script.

L’utilisateur reconnaît avoir lu et compris cette clause et accepte de ne pas tenir l’auteur responsable de toute conséquence liée à l’usage de ce script.

---




