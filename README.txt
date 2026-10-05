DAM
Menu bar control for displays and audio.

AUDIO
  * Switch audio output

CONNECT
  * AirPlay displays and Sidecar iPads
  * Auto-connect a plugged-in iPad when it's the only display

DISPLAYS
  * Resolution and refresh rate, including virtual ones
  * Mirror, extend, optimize a mirror set
  * Main display and position
  * Arrange by drag and drop

CONTROL
  * Global hotkeys: switcher, AirPlay quick-connect,
    mirror, audio, main display
  * Touch Bar
  * On-screen and spoken announcements

SETTINGS
  * Display nicknames, hidden devices, launch at login

VERIFYING A RELEASE
  Releases are signed with the SSH key in allowed_signers:
    ssh-keygen -Y verify -f allowed_signers -I dam-release -n file \
      -s DAM-vX.Y.zip.sig < DAM-vX.Y.zip
