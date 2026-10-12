# Steam desktop client in a browser-accessible container (noVNC on 5800,
# VNC on 5900). Purpose: download, cache and keep games updated so other PCs
# on the LAN can pull them via Steam's Local Network Game Transfers.
# No gaming, no streaming, no GPU.
FROM jlesage/baseimage-gui:debian-13-v4

# Steam's bootstrapper is a Debian package and still pulls 32-bit libraries,
# which Alpine cannot provide. Hence Debian 13.
ENV DEBIAN_FRONTEND=noninteractive

# jlesage replaces /var/log with a symlink. Debian 13's systemd postinst runs
# `mkdir /var/log` and fails with "File exists" while that symlink is present,
# so turn it into a real directory during apt and restore the symlink after.
#
# Packages beyond what steam.deb pulls in:
#   libgl1/libdrm2/libgbm1 (+i386), libnss3, libxss1, libgtk-3-0t64
#                          runtime libs for the client and its CEF web UI
#   libgl1-mesa-dri (+i386), libegl1, libegl-mesa0
#                          Mesa: llvmpipe software GL when there is no GPU,
#                          and the radeonsi/iris/... drivers when /dev/dri is
#                          passed in (optional GPU mode, see README)
#   mesa-vulkan-drivers    64-bit only; lets Steam's system probe see the GPU
#                          via Vulkan. Optional, drop it to save space.
#   zenity                 used by Steam's scripts and by our first-run notice
#   pciutils               lspci, used by Steam's hardware/system-info probe
#   locales                en_US.UTF-8 (avoids "locale not supported" warnings)
#   dbus-daemon            private D-Bus session bus, started in startapp.sh
#   xdg-desktop-portal, xdg-desktop-portal-gtk
#                          folder picker for Settings > Storage > Add Drive >
#                          "Let me choose another location". Steam asks the
#                          portal's FileChooser over D-Bus; without a working
#                          portal it falls back to a built-in picker that is
#                          known to show an empty, unusable dialog. GTK 3 is
#                          already installed, so the GTK backend adds little.
RUN set -eux; \
    log_target="$(readlink /var/log || true)"; \
    rm -f /var/log; \
    mkdir -p /var/log; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libgl1 libgl1:i386 \
        libgl1-mesa-dri libgl1-mesa-dri:i386 \
        libegl1 libegl-mesa0 \
        mesa-vulkan-drivers \
        libdrm2 libdrm2:i386 \
        libgbm1 libgbm1:i386 \
        libnss3 libxss1 \
        libgtk-3-0t64 \
        xz-utils zenity \
        pciutils \
        locales \
        dbus-daemon \
        xdg-desktop-portal xdg-desktop-portal-gtk; \
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; \
    locale-gen; \
    curl -fsSL -o /tmp/steam.deb https://cdn.akamai.steamstatic.com/client/installer/steam.deb; \
    apt-get install -y /tmp/steam.deb; \
    rm -rf /var/lib/apt/lists/* /tmp/steam.deb; \
    # steam.deb adds Valve's apt repo, and its launcher runs steamdeps on every
    # start. With the apt lists removed, steamdeps decides the cache is out of
    # date and opens an xterm that tries to run apt as root via pkexec, which
    # can't work in a container. All dependencies are installed at build time,
    # so drop the repo entry and switch the check off.
    rm -f /etc/apt/sources.list.d/steam*.list /etc/apt/sources.list.d/steam*.sources; \
    chmod a-x /usr/lib/steam/bin_steamdeps.py; \
    if [ -n "$log_target" ]; then \
        rm -rf /var/log; \
        ln -s "$log_target" /var/log; \
    fi

ENV LANG=en_US.UTF-8

# rootfs/ mirrors the container layout:
#   /startapp.sh                               launches Steam (as the app user)
#   /etc/openbox/main-window-selection.xml     maximise only the main window;
#                                              menus and dialogs stay free
#   /etc/xdg-desktop-portal/portals.conf       use the GTK portal backend
#   /usr/local/bin/steam-library-register      vdf edit used by startapp.sh
#   /usr/local/bin/add-steam-library           `docker exec` helper
COPY rootfs/ /

# fastcompmgr (the baseimage's compositor) is not needed for Steam; disabling
# it is harmless and removes one moving part.
RUN chmod 755 /startapp.sh /usr/local/bin/steam-library-register /usr/local/bin/add-steam-library \
    && if [ -d /etc/services.d/fastcompmgr ]; then touch /etc/services.d/fastcompmgr/disabled; fi \
    && set-cont-env APP_NAME "Steam"
