#!/bin/bash
# Generate the TOAST boot wallpaper that replaces Clonezilla's orange one.
#
# ⛔ IT HAS TO STAY LIGHT. The menu text colour is not ours: both syslinux configs
# carry `MENU COLOR UNSEL 7;32;41 #c0000090 #00000000`, i.e. DARK BLUE text on a
# transparent background, drawn straight over the wallpaper. A dark or busy
# background makes the menu unreadable, and changing the text colours instead
# would mean editing colour directives in three boot configs. So: pale field
# where the menu sits, branding confined to a band at the bottom.
#
# 640x480 to match the files being replaced (syslinux/ocswp.png and
# boot/grub/ocswp-grub2.png are both that size).
#
# Colours and fonts come from a brand directory that is NOT in this repo: the
# wordmark and licensed typeface belong to whoever ships the kit. Point BRAND
# at your own, or skip this script and drop a 640x480 PNG in as toast-bg.png.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BRAND=${BRAND:-$HERE/brand}
OUT="${1:-$HERE/toast-bg.png}"

FONT_BOLD="$BRAND/fonts/Poppins-Bold.ttf"
FONT_MED="$BRAND/fonts/Poppins-Medium.ttf"
# Dark wordmark, because the band it sits on is pale.
LOGO_DARK="$BRAND/toast-logo.png"

# ⛔ THE BOTTOM BAND MUST BE PALE, NOT BLUE. GRUB draws its own help lines
# ("Use the arrow keys...", "Press enter to boot...") at the very BOTTOM of the
# screen in dark text, straight over whatever is there. A solid blue band put
# dark text on dark blue and collided with the wordmark. vesamenu on legacy BIOS
# draws its help higher up, so this only showed on the UEFI path. Caught by
# booting it, 2026-09-04. Pale band + dark ink is readable under both.
BAND_BG='#D6E4F0'  # house pale blue fill
BAND_FG='#1F4E79'  # house heading blue, dark enough to read on the above
GOLD='#FFB900'     # TOAST Gold, Pantone 7549C
GREY='#EAEBEC'     # TOAST Grey
INK='#12151D'      # Website Black

W=640; H=480
BAND=64                      # height of the bottom brand band
RULE=4                       # gold rule above it
FIELD=$((H - BAND - RULE))   # pale area the menu is drawn over

for f in "$FONT_BOLD" "$FONT_MED" "$LOGO_DARK"; do
    [ -r "$f" ] || { echo "missing brand asset: $f" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Pale field: white at the top where the first menu entries sit, easing into
# TOAST Grey lower down. Nothing else goes here.
convert -size "${W}x${FIELD}" "gradient:#FFFFFF-${GREY}" "$tmp/field.png"

# Bottom band.
convert -size "${W}x${BAND}" "xc:${BAND_BG}" "$tmp/band.png"

# TOAST wordmark sized to the band, kept to its real aspect ratio. Brand
# Guidelines section 3 forbids distorting the logo, so scale by height only.
convert "$LOGO_DARK" -resize x22 "$tmp/logo.png"

# ⛔ Nothing goes on the LEFT of the band. GRUB writes three left-aligned help
# lines across it, and anything underneath them just looks like a collision even
# when both are readable. The wordmark goes at the right, where GRUB's help ends;
# the TOAST name goes in the pale field above the band instead.
cp "$tmp/band.png" "$tmp/band2.png"

# Wordmark bottom-right, with a comfortable margin.
LOGO_W=$(identify -format '%w' "$tmp/logo.png")
convert "$tmp/band2.png" "$tmp/logo.png" \
    -geometry "+$((W - LOGO_W - 18))+21" -composite "$tmp/band3.png"

# Assemble: field, gold rule, band.
convert -size "${W}x${RULE}" "xc:${GOLD}" "$tmp/rule.png"
convert "$tmp/field.png" "$tmp/rule.png" "$tmp/band3.png" -append "$tmp/base.png"

# A restrained watermark, low in the pale field so it sits under the help line
# rather than under the menu entries. Very low contrast on purpose.
# ⛔ -depth 8 AND a plain non-interlaced truecolour PNG ARE LOAD-BEARING.
# The gradient makes ImageMagick emit a 16-BIT PNG, and GRUB's own PNG reader
# only understands 8-bit. A 16-bit background does not fail cleanly: GRUB draws
# the menu over rainbow scanline garbage and the whole screen is unreadable.
# Legacy BIOS/vesamenu was perfectly happy with the same file, so this only shows
# up on the UEFI path. Caught by booting it, 2026-09-04. The file being replaced
# is 8-bit sRGB; match that.
# The TOAST name, low in the pale field so it sits clear of both the menu box
# above and GRUB's help lines below.
convert "$tmp/base.png" \
    -font "$FONT_BOLD" -pointsize 15 -fill "${BAND_FG}" \
    -draw "fill-opacity 0.55 text 18,$((FIELD - 26)) 'TOAST'" \
    -font "$FONT_MED" -pointsize 9 -fill "${INK}" \
    -draw "fill-opacity 0.40 text 18,$((FIELD - 12)) \"TOAST's Official Automated Sysprep Toolkit\"" \
    -depth 8 -interlace none -define png:color-type=2 -define png:bit-depth=8 \
    -strip "$OUT"

# Refuse to hand over anything GRUB cannot read.
depth=$(identify -format '%z' "$OUT")
ilace=$(identify -format '%[interlace]' "$OUT")
if [ "$depth" != "8" ]; then
    echo "make-background: produced a ${depth}-bit PNG; GRUB needs 8-bit" >&2
    rm -f "$OUT"; exit 1
fi
if [ "$ilace" != "None" ] && [ -n "$ilace" ]; then
    echo "make-background: produced an interlaced PNG ($ilace); GRUB needs none" >&2
    rm -f "$OUT"; exit 1
fi

identify "$OUT"
