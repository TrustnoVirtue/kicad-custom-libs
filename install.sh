#!/usr/bin/env bash
#
# Installs the custom KiCad footprint libraries and 3D models from this
# repository into a local KiCad installation and registers them in
# KiCad's fp-lib-table.
#
# Usage:
#   ./install.sh
#   KICAD_VERSION=10.0 ./install.sh
#   INSTALL_DIR="$HOME/kicad-libs" CONFIG_DIR="$HOME/.config/kicad/10.0" ./install.sh
#
# Environment variables:
#   KICAD_VERSION  KiCad version folder (auto-detected when omitted)
#   INSTALL_DIR    target folder for the libraries
#                  (default: ~/Documents/KiCad/<version>/kicad-custom-libs)
#   CONFIG_DIR     folder containing fp-lib-table
#                  (default: ~/.config/kicad/<version> or
#                   ~/Library/Preferences/kicad/<version> on macOS)
#   NO_REGISTER    set to 1 to skip fp-lib-table registration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR"
TABLE=""

die() { echo "Error: $*" >&2; exit 1; }

[ -d "$REPO/footprints" ] || die "footprints/ not found next to this script. Run the script from the repository root."
[ -d "$REPO/3dmodels" ] || die "3dmodels/ not found next to this script."

case "$(uname -s)" in
    Darwin) CONFIG_BASE="$HOME/Library/Preferences/kicad" ;;
    *)      CONFIG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}/kicad" ;;
esac

VERSION="${KICAD_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(ls -1 "$CONFIG_BASE" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1 || true)"
fi
[ -n "$VERSION" ] || die "Could not detect a KiCad version under $CONFIG_BASE. Set KICAD_VERSION, for example: KICAD_VERSION=10.0 ./install.sh"

CONFIG_DIR="${CONFIG_DIR:-$CONFIG_BASE/$VERSION}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Documents/KiCad/$VERSION/kicad-custom-libs}"
INSTALL_DIR="${INSTALL_DIR%/}"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        if command -v cygpath >/dev/null 2>&1; then
            INSTALL_DIR="$(cygpath -m "$INSTALL_DIR")"
            CONFIG_DIR="$(cygpath -m "$CONFIG_DIR")"
        else
            echo "Warning: Git Bash/MSYS detected. Prefer install.ps1 on Windows so KiCad gets native paths." >&2
        fi
        ;;
esac

if pgrep -x kicad >/dev/null 2>&1 || pgrep -x eeschema >/dev/null 2>&1; then
    echo "Warning: KiCad appears to be running. Close it after the install so it does not overwrite fp-lib-table." >&2
fi

echo "KiCad version : $VERSION"
echo "Install folder: $INSTALL_DIR"
echo "Config folder : $CONFIG_DIR"

command -v perl >/dev/null 2>&1 || die "perl is required for 3D model path rewriting."

mkdir -p "$INSTALL_DIR/footprints" "$INSTALL_DIR/3dmodels"
cp -R "$REPO/footprints/." "$INSTALL_DIR/footprints/"
cp -R "$REPO/3dmodels/." "$INSTALL_DIR/3dmodels/"

echo "Rewriting 3D model paths in installed footprints..."
export INSTALL_DIR
find "$INSTALL_DIR/footprints" -name '*.kicad_mod' -print0 | while IFS= read -r -d '' file; do
    perl -0777 -pi -e '
        my $root = $ENV{INSTALL_DIR};
        $root =~ s{\\}{/}g;
        $root =~ s{/+$}{};
        my @map = (
            ["\${EASYEDA2KICAD}/easyeda2kicad.3dshapes/", "$root/3dmodels/easyeda2kicad.3dshapes/"],
            ["C:/Users/Vvirtue/Documents/KiCad/10.0/3dmodels/", "$root/3dmodels/"],
            ["C:/Users/Vvirtue/AppData/Local/KiCadComponentImporter/global_libraries/3DModels/", "$root/3dmodels/"],
            ["C:/Users/Vvirtue/Pictures/Import/3d/", "$root/3dmodels/new_footprint.3dshapes/"],
        );
        for my $pair (@map) { s{\Q$pair->[0]\E}{$pair->[1]}g; }
        s{\(model "ZMPT101B\.stp"}{\(model "$root/3dmodels/new_footprint.3dshapes/ZMPT101B.stp"}g;
    ' "$file"
done

if [ "${NO_REGISTER:-0}" != "1" ]; then
    mkdir -p "$CONFIG_DIR"
    TABLE="$CONFIG_DIR/fp-lib-table"
    export TABLE
    perl -e '
        my $table = $ENV{TABLE};
        my $root  = $ENV{INSTALL_DIR};
        $root =~ s{\\}{/}g;
        $root =~ s{/+$}{};
        my @names = ("easyeda2kicad", "IPEX-1", "JST_PH_2P", "new_footprint", "PinHeader_2P", "Project_Components", "SK-3296S-01-L2", "TYPEC-304J-BCP16", "Ziisor_IPEX-1");
        my %uri;
        for my $n (@names) { $uri{$n} = "$root/footprints/$n.pretty"; }
        my @lines;
        if (-e $table) {
            open(my $fh, "<", $table) or die "cannot read $table: $!";
            @lines = <$fh>;
            close($fh);
            chomp @lines;
        }
        else {
            @lines = ("(fp_lib_table", "\t(version 7)", ")");
        }
        my $alt = join("|", map { quotemeta($_) } @names);
        @lines = grep { !/^\s*\(lib\s+\(name\s+"(?:$alt)"\)/ } @lines;
        my @entries = map {
            "\t(lib (name \"$_\") (type \"KiCad\") (uri \"$uri{$_}\") (options \"\") (descr \"Installed by the kicad-custom-libs installer\"))"
        } @names;
        my $idx = -1;
        for (my $i = $#lines; $i >= 0; $i--) {
            if ($lines[$i] =~ /^\s*\)\s*$/) { $idx = $i; last; }
        }
        if ($idx >= 0) { splice(@lines, $idx, 0, @entries); }
        else { push(@lines, @entries); }
        open(my $out, ">", $table) or die "cannot write $table: $!";
        print $out join("\n", @lines), "\n";
        close($out);
    '
    echo "Registered 9 libraries in $TABLE"
fi

echo ""
echo "Done. Open KiCad -> Preferences -> Manage Footprint Libraries to verify the libraries."
echo "The 3D models are installed next to the footprints and referenced by absolute path."
