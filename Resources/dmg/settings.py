# dmgbuild layout for MultiCopy.dmg, used by release.sh.
# Icon positions must line up with the arrow drawn in background.png.
app = defines["app"]

files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]              # volume icon shown when the DMG is mounted
background = defines["background"]  # background@2x.png is picked up automatically

format = "ULFO"                     # LZFSE compression, opens on macOS 10.11+
filesystem = "HFS+"

window_rect = ((200, 120), (600, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {
    "MultiCopy.app": (150, 170),
    "Applications": (450, 170),
}
