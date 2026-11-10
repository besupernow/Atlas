#!/bin/bash
chmod +x /usr/bin/atlas
chmod +x /opt/atlas/atlas
chmod +x /opt/atlas/lib/gstreamer-1.0/gst-plugin-scanner 2>/dev/null || true
chmod +x /opt/atlas/lib/crashpad_handler 2>/dev/null || true

if command -v gtk-update-icon-cache &> /dev/null; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi

if command -v update-desktop-database &> /dev/null; then
    update-desktop-database /usr/share/applications || true
fi
