# Paires

Un clône du jeu "Qui Paire Gagne" avec des images aléatoires obtenues via l'API Unsplash.

## Démarrage

Pour démarrer le serveur :

* Installer les dépendances avec `mix deps.get`
* Installer les dépendances Node.js avec `npm install` dans le dossier `assets`
* Démarrer le serveur avec `mix phx.server`

Vous pouvez ensuite visiter [`localhost:4000`](http://localhost:4000) dans votre navigateur.

## Docker

Pour démarrer le serveur dans Docker, aller dans le dossier `release` et modifier le fichier `docker-compose.yml` pour y entrer vos variables d'environnement.

La variable `SECRET_KEY` doit contenir une clé générée avec la commande `mix phx.gen.secret`.

Une fois le fichier modifié, démarrer le serveur avec la commande `docker-compose up`.

## Fonctionnement.

Pour démarrer une partie ou joindre une partie existante, il suffit d'entrer un nom de joueur et un nom de salle.

Si la salle n'existe pas, elle sera créée automatiquement. La salle est détruite et son score est réinitialisé dès qu'il n'y a plus aucun joueur dedans.

Des joueurs peuvent se joindre ou quitter une partie à tout moment, mais la partie est annulée si la salle contient moins de 3 joueurs.

Pour annuler une partie en cours, une majorité de joueurs doivent voter pour annuler la partie avec le bouton "Annuler". Cela a pour effet de redémarrer la partie.

À plusieurs moments durant la partie, les joueurs doivent voter pour passer à la prochaine étape. Le vote est terminé dès qu'une majorité des joueurs ont voté.
