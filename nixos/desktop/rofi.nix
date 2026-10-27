{
  pkgs,
  lib,
  config,
  ...
}:
let
  theme = import ./theme.nix {
    inherit lib;
    name = config.nox.desktop.theme;
  };
in
{
  environment.systemPackages = with pkgs; [
    rofi # application launcher
  ];

  environment.etc = {
    "xdg/rofi/config.rasi" = {
      text = ''
        // Config //
        configuration {
            modi:                        "drun,filebrowser,window,run";
            show-icons:                  true;
            display-drun:                " ";
            display-run:                 " ";
            display-filebrowser:         " ";
            display-window:              " ";
            drun-display-format:         "{name}";
            window-format:               "{w}{t}";
            font:                        "${theme.font.family} ${toString theme.font.launcherSize}";
            icon-theme:                  "${theme.icons.name}";
        }

        @theme "/etc/xdg/rofi/theme.rasi"


        // Main //
        window {
            width:                       35em;
            transparency:                "real";
            fullscreen:                  false;
            enabled:                     true;
            cursor:                      "default";
            spacing:                     0em;
            padding:                     0em;
            border:                      0px;
            border-radius:               ${toString theme.radius}px;
            border-color:                @main-br;
            background-color:            @main-bg;
        }
        mainbox {
            enabled:                     true;
            spacing:                     1em;
            padding:                     1em;
            orientation:                 vertical;
            children:                    [ "inputbar" , "listview" ];
            background-color:            transparent;
        }


        // Inputs //
        inputbar {
            enabled:                     true;
            spacing:                     0.5em;
            padding:                     0.6em 1em;
            children:                    [ "prompt" , "entry" ];
            border-radius:               ${toString theme.radiusInner}px;
            background-color:            @input-bg;
            text-color:                  @main-fg;
        }
        prompt {
            enabled:                     true;
            background-color:            transparent;
            text-color:                  @main-ex;
        }
        entry {
            enabled:                     true;
            placeholder:                 "Search";
            placeholder-color:           @muted-fg;
            cursor:                      text;
            background-color:            transparent;
            text-color:                  inherit;
        }


        // Lists //
        listview {
            enabled:                     true;
            spacing:                     0.25em;
            padding:                     0em;
            columns:                     1;
            lines:                       8;
            cycle:                       true;
            dynamic:                     true;
            scrollbar:                   false;
            layout:                      vertical;
            reverse:                     false;
            fixed-height:                true;
            fixed-columns:               true;
            cursor:                      "default";
            background-color:            transparent;
            text-color:                  @main-fg;
        }


        // Elements //
        element {
            enabled:                     true;
            spacing:                     1em;
            padding:                     0.5em 1em;
            cursor:                      pointer;
            border-radius:               ${toString theme.radiusInner}px;
            background-color:            transparent;
            text-color:                  @main-fg;
        }
        element selected.normal {
            background-color:            @select-bg;
            text-color:                  @select-fg;
        }
        element-icon {
            size:                        2em;
            cursor:                      inherit;
            background-color:            transparent;
            text-color:                  inherit;
        }
        element-text {
            vertical-align:              0.5;
            horizontal-align:            0.0;
            cursor:                      inherit;
            background-color:            transparent;
            text-color:                  inherit;
        }

        // Error message //
        error-message {
            text-color:                  @main-fg;
            background-color:            @main-bg;
            text-transform:              capitalize;
            children:                    [ "textbox" ];
        }

        textbox {
            text-color:                  inherit;
            background-color:            inherit;
            vertical-align:              0.5;
            horizontal-align:            0.5;
        }
      '';
    };
    # Colors from home/desktop/theme.nix
    "xdg/rofi/theme.rasi" = {
      text = ''
        * {
            main-bg:            ${theme.withAlpha "bg" theme.opacity.launcher};
            main-fg:            ${theme.color.fg};
            main-br:            ${theme.color.accent};
            main-ex:            ${theme.color.accent};
            input-bg:           ${theme.withAlpha "bgDark" 0.6};
            muted-fg:           ${theme.color.muted};
            select-bg:          ${theme.color.accent2};
            select-fg:          ${theme.color.bg};
            separatorcolor:     transparent;
            border-color:       transparent;
        }
      '';
    };
  };
}
