# dmgbuild settings for the Jutsu Studio installer window. scripts/release.sh passes -D app=<Jutsu Studio.app>
# and -D background=<this folder>/background.png (dmgbuild runs this file without __file__). Icon positions match
# the layout drawn in background.html.
import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(application)

format = "ULFO"  # LZFSE: smaller than UDZO, opens on macOS 10.11 and later
filesystem = "APFS"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")

# background@2x.png next to it is picked up for Retina screens.
background = defines["background"]  # noqa: F821
window_rect = ((200, 160), (680, 420))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (180, 214),
    "Applications": (500, 214),
}
