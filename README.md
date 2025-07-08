# Zimbra Migration Tools

**Scripts Bash pour faciliter la migration complète d’un serveur Zimbra vers un autre.**

---

## 🚀 Objectif

Ce dépôt rassemble un ensemble d’outils et scripts shell conçus pour automatiser et sécuriser les étapes clés de la migration d’une instance Zimbra vers une nouvelle machine ou version, en minimisant les interruptions de service.

---

## 📦 Contenu

- Scripts pour sauvegarder les données Zimbra (mailboxes, configurations, LDAP, etc.)
- Scripts de restauration et d’import sur la nouvelle instance
- Outils de vérification d’intégrité post-migration
- Instructions et automatisation des étapes répétitives

---

## ⚙️ Fonctionnalités principales

- Sauvegarde automatisée et cohérente des données Zimbra
- Transfert sécurisé des fichiers entre serveurs via rsync
- Reconfiguration rapide des paramètres réseau et DNS
- Validation de la santé des services après migration
- Support pour Zimbra Open Source (FOSS) et versions courantes

---

## 📋 Prérequis

- Serveurs source et destination Zimbra sous Linux avec accès SSH
- Droits root ou utilisateur `zimbra` sur les deux machines
- Bash, rsync, ssh, et utilitaires standards Linux installés
- Connexion réseau fiable entre serveurs

---

## 📖 Usage

1. Cloner ce dépôt sur la machine source ou destination :

```bash
git clone https://github.com/cdoukoure/zimbra-migration-tools.git
cd zimbra-migration-tools
```
Les scripts doivent etre exécutés par numéro d'ordre dans le nom du fichier.

```
├───1- Sur_Serveurs_Source_MBOX
│       0_zimbra_export_accounts_v12.sh
│       1_zimbra_generate_import_scripts.sh
│       2_zimbra_export_accounts_mailbox.sh # Voir la note plus bas
│
└───2- Sur_Serveurs_Destination_MBOX
        0_zimbra_import_accounts.sh
        1_zimbra_domain_admin.sh
        2_zimbra_remote_export_mailbox.sh 
        3_zimbra_import_accounts_mailbox.sh
        README.md
```

Pour l'export des mailbox sur le serveur source, lancer `2_zimbra_export_accounts_mailbox.sh`. Ce script utilise `zmmailbox` pour l'export des mailbox; Vous aurez besion de `rsync` pour les transférer sur le serveur de destination. <br>
Sinon vous pouvez utiliser directement `2_zimbra_remote_export_mailbox.sh` depuis le serveur de destination. Plus besion de `rsync` dans ce cas.

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

