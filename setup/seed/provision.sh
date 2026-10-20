#!/bin/bash
set -Eeuo pipefail
exec >>/var/log/portable-linux-setup.log 2>&1
export DEBIAN_FRONTEND=noninteractive

report() { printf '%s\n' "$*" | tee /dev/ttyS0; }
failed() {
    local code=$?
    trap - ERR
    report "PORTABLE_LINUX_SETUP_FAILED exit=$code; see /var/log/portable-linux-setup.log"
    tail -n 20 /var/log/portable-linux-setup.log >/dev/ttyS0 || true
    sync
    systemctl poweroff --no-block || true
    exit "$code"
}
trap failed ERR

report 'PORTABLE_LINUX_STAGE: preparing packages'
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true
systemctl mask ssh.service ssh.socket || true
dpkg --configure -a
apt-get -o DPkg::Lock::Timeout=180 -o Dpkg::Use-Pty=0 update
apt-get -o DPkg::Lock::Timeout=180 -o Dpkg::Use-Pty=0 install -y --no-install-recommends \
    linux-image-generic xserver-xorg-core xserver-xorg-video-all \
    xserver-xorg-input-libinput xinit x11-xserver-utils \
    xfce4 xfce4-terminal dbus-x11 fonts-dejavu-core \
    adwaita-icon-theme librsvg2-common at-spi2-core tumbler \
    mousepad curl git nano ca-certificates

report 'PORTABLE_LINUX_STAGE: configuring desktop and local login'
install -d /etc/systemd/system/getty@tty1.service.d \
    /etc/systemd/system/serial-getty@ttyS0.service.d /etc/X11/xorg.conf.d
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ubuntu --noclear %I $TERM
EOF
cat >/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ubuntu --noclear --keep-baud 115200,38400,9600 %I $TERM
EOF
cat >/etc/X11/xorg.conf.d/20-portable-gpu.conf <<'EOF'
Section "Device"
    Identifier "PortableGPU"
    Driver "modesetting"
    Option "AccelMethod" "none"
EndSection
EOF

install -d -o ubuntu -g ubuntu /home/ubuntu/work /home/ubuntu/Pictures \
    /home/ubuntu/.config/autostart /home/ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml
cat >/home/ubuntu/.bash_profile <<'EOF'
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = /dev/tty1 ] && grep -q 'PortableUbuntu-Desktop' /sys/class/dmi/id/product_name; then
    startx -- -nolisten tcp
fi
EOF
cat >/home/ubuntu/.xinitrc <<'EOF'
#!/bin/sh
/usr/local/bin/portable-display-auto || true
exec dbus-run-session -- startxfce4
EOF
chmod 755 /home/ubuntu/.xinitrc

cat >/usr/local/bin/portable-display-auto <<'EOF'
#!/bin/sh
# The QEMU launcher advertises the current host's size via virtual EDID.
# --auto picks that preferred mode, rather than stretching a 640x480 image.
output=$(xrandr --query | awk '/ connected/{print $1; exit}')
if [ -n "$output" ]; then
    xrandr --output "$output" --auto
fi
EOF
chmod 755 /usr/local/bin/portable-display-auto
cat >/home/ubuntu/.config/autostart/portable-display.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Portable display auto size
Exec=sh -c "sleep 3; /usr/local/bin/portable-display-auto"
OnlyShowIn=XFCE;
Terminal=false
EOF

cat >/home/ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0"><property name="general" type="empty"><property name="use_compositing" type="bool" value="false"/></property></channel>
EOF
cat >/home/ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="desktop-icons" type="empty"><property name="icon-size" type="uint" value="64"/></property>
  <property name="backdrop" type="empty"><property name="screen0" type="empty"><property name="monitorVirtual-1" type="empty"><property name="workspace0" type="empty">
    <property name="last-image" type="string" value="/home/ubuntu/Pictures/phim-tat-ubuntu.png"/>
    <property name="image-style" type="int" value="5"/>
  </property></property></property></property>
</channel>
EOF
cat >/home/ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0"><property name="Net" type="empty"><property name="IconThemeName" type="string" value="Adwaita"/></property></channel>
EOF
install -m 644 /usr/local/share/backgrounds/portable-shortcuts.png /home/ubuntu/Pictures/phim-tat-ubuntu.png
printf 'portable-ubuntu-persistence-ok\n' >/home/ubuntu/work/SSD-PERSISTENCE.txt
chown -R ubuntu:ubuntu /home/ubuntu

cat >/usr/share/applications/portable-poweroff.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Shut down Portable Ubuntu
Comment=Shut down safely before ejecting the SSD
Exec=sudo -n /sbin/poweroff
Icon=system-shutdown
Terminal=false
Categories=System;
EOF
cat >/etc/systemd/system/portable-ready.service <<'EOF'
[Unit]
Description=Report an already provisioned portable Ubuntu on the local serial console
ConditionPathExists=/var/lib/portable-linux-ready
After=systemd-user-sessions.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo PORTABLE_LINUX_GUEST_READY > /dev/ttyS0'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/motd <<'EOF'
Portable Ubuntu 24.04 LTS on an external SSD
User: ubuntu | Work: ~/work | Tools: sudo apt install <package>
Safe shutdown: sudo poweroff
Local automatic login. Set a personal password: sudo passwd ubuntu
EOF

report 'PORTABLE_LINUX_STAGE: verifying installation'
audit=$(dpkg --audit)
if [ -n "$audit" ]; then printf '%s\n' "$audit"; false; fi
apt-get check
dpkg-query -W xfce4 thunar librsvg2-common xinit xserver-xorg-core curl git
curl --retry 2 -fsS --max-time 45 -o /dev/null https://archive.ubuntu.com/ubuntu/
systemctl disable --now ssh.service ssh.socket || true
systemctl mask ssh.service ssh.socket
systemctl disable portable-provision.service
systemctl set-default multi-user.target
systemctl daemon-reload
systemctl enable portable-ready.service
apt-get clean
touch /etc/cloud/cloud-init.disabled
touch /var/lib/portable-linux-ready
sync
report 'PORTABLE_LINUX_SETUP_SUCCESS'
systemctl poweroff --no-block
