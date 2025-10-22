# steamdeck-fnmap

🚀 Quick Start
1. Prerequisites

Before running the setup script, ensure:

You’re in Desktop Mode on the Steam Deck.

You’ve connected to the internet.

You’ve disabled read-only mode temporarily:

sudo steamos-readonly disable

2. Clone or Copy Files

If you already have this repo locally (via GitHub clone or USB), open a terminal in the same folder that contains:

bootstrap_fnmap.sh

FNMAP_Setup_Instructions.txt

If not, you can clone the repo directly:

git clone https://github.com/grmcrkrs/steamdeck-fnmap.git
cd steamdeck-fnmap

3. Run the Setup Script

Make it executable:

chmod +x bootstrap_fnmap.sh


Then run it:

./bootstrap_fnmap.sh


This will:

Ensure sudo steamos-readonly disable is applied.

Install all build dependencies (Flutter SDK, GTK, GLib, X11 headers, etc.).

Set environment paths and fix missing include directories.

Clone and build FNMap from GitHub.

Register a launcher entry in your Steam Deck app menu.

4. Launching FNMap

Once the build completes, you can launch FNMap by:

~/fnmap/build/linux/x64/release/bundle/fnmap


Or from the Applications → Internet → FNMap menu entry.

If it requests a password, that’s normal (root privileges allow socket access).
Later, you can configure it for passwordless access via sudoers.d rules.

5. Re-enable Read-Only Mode (Optional)

If you want to restore system protection after setup:

sudo steamos-readonly enable

🧠 Notes

If Flutter or pkg-config dependencies fail, re-run the script.

The script performs checks for missing libraries and installs them automatically.

You can safely re-run it after a SteamOS update or fresh reinstall.

Ideal for restoring FNMap after a drive replacement.
