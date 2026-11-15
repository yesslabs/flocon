# Outils communs aux étapes du test (à charger avec : . ci/outils.sh)
ordre() { ci/ordre.sh "$@"; }
pilote() { ordre com.yessen.flocon.pilote "$1"; }
vivant() { pgrep -x Flocon >/dev/null || { echo "::error::Flocon s'est arrêté ($1)"; exit 1; }; }
photo() { screencapture -x "shots/$1.png"; vivant "$1"; }
# pour ce qui dépend des autorisations de la machine de test : un échec est signalé sans arrêter le test
essai() { perl -e 'alarm shift; exec @ARGV' 45 "$@" || echo "::warning::étape impossible sur cette machine : $*"; }
fenetre() { ordre flocon.test.fenetre "$1"; }
