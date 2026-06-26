# Add GUI recovery dependencies through Armbian's package aggregation API.
# Using add_packages_to_image() keeps EXTRA_PACKAGES_IMAGE and its provenance
# reference list in sync on current Armbian framework revisions.
function extension_prepare_config__rk322x_gui_packages() {
    local extension_name="${EXTENSION:-rk322x-gui-packages}"

    display_alert \
        "Extension: ${extension_name}: Adding RK322x GUI recovery packages" \
        "lightdm-gtk-greeter xserver-xorg-video-fbdev" \
        "info"

    # network-manager-gnome is already supplied by the official
    # net-network-manager extension for desktop images.
    add_packages_to_image \
        lightdm-gtk-greeter \
        xserver-xorg-video-fbdev
}
