#!/bin/bash
# Removes Serpentis and its settings. Button assignments saved in the mouse stay until you reset them.
echo "This removes Serpentis, its login item and its saved profiles/layouts."
read -p "Type Y and press Return to continue: " ans
[ "$ans" = "Y" ] || [ "$ans" = "y" ] || { echo "Cancelled."; exit 0; }
pkill -x Serpentis 2>/dev/null; sleep 1
rm -rf /Applications/Serpentis.app
rm -f ~/Library/LaunchAgents/com.davewoods.serpentis.plist
defaults delete com.davewoods.serpentis 2>/dev/null
echo "Serpentis has been removed."
echo "Tip: to put the mouse's buttons back to factory settings, use Serpentis > Buttons > Reset All before uninstalling,"
echo "or any computer with Razer Synapse."
