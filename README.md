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
