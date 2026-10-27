# plymouth theme "nox": the NoX wallpaper (nox-branding, the theme's colors)
# full screen, the passphrase in a translucent field below the logo (no prompt text), and the
# boot in short form: the last systemd status lines in a translucent panel at
# the bottom (older lines fade). Esc shows the full boot messages (plymouth's
# console view). Script plugin, so no compiled code.
{
  lib,
  runCommand,
  writeText,
  resvg,
  # nox-branding output (share/nox/wallpaper.png)
  branding,
  # desktop/theme.nix `raw` roles, hex without '#'
  colors,
}:
let
  color = import ../nixos/lib/color.nix { inherit lib; };
  # "rrggbb" -> "r, g, b" as 0..1 for the script
  rgb = hex: lib.concatMapStringsSep ", " (c: toString (c / 255.0)) (color.toRgb hex);

  # Translucent panels (rounded, the theme's dark background and border)
  panel =
    w: h:
    writeText "panel-${toString w}x${toString h}.svg" ''
      <svg xmlns="http://www.w3.org/2000/svg" width="${toString w}" height="${toString h}">
        <rect x="1" y="1" width="${toString (w - 2)}" height="${toString (h - 2)}" rx="12"
          fill="#${colors.bgDark}" fill-opacity="0.72" stroke="#${colors.border}" stroke-width="2"/>
      </svg>
    '';
  bullet = writeText "bullet.svg" ''
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">
      <circle cx="8" cy="8" r="6" fill="#${colors.accent}"/>
    </svg>
  '';

  # Font of the text (boot.plymouth.font, desktop/plymouth.nix)
  font = "FiraCode Nerd Font";

  script = writeText "nox.script" ''
    W = Window.GetWidth();
    H = Window.GetHeight();
    X = Window.GetX();
    Y = Window.GetY();
    Window.SetBackgroundTopColor(${rgb colors.bgDark});
    Window.SetBackgroundBottomColor(${rgb colors.bgDark});

    # The wallpaper covers the screen (scaled, centered, cropped)
    bg.image = Image("background.png");
    bg.ratio = Math.Max(W / bg.image.GetWidth(), H / bg.image.GetHeight());
    bg.scaled = bg.image.Scale(bg.image.GetWidth() * bg.ratio, bg.image.GetHeight() * bg.ratio);
    bg.sprite = Sprite(bg.scaled);
    bg.sprite.SetPosition(X + (W - bg.scaled.GetWidth()) / 2, Y + (H - bg.scaled.GetHeight()) / 2, -100);

    #------------------------------ boot status (short) ------------------------------
    LINES = 6;
    log.panel.image = Image("log.png");
    log.panel.sprite = Sprite(log.panel.image);
    log.x = X + W / 2 - log.panel.image.GetWidth() / 2;
    log.y = Y + H - log.panel.image.GetHeight() - H * 0.03;
    log.panel.sprite.SetPosition(log.x, log.y, 10);
    for (i = 0; i < LINES; i++)
      {
        log.text[i] = "";
        log.sprite[i] = Sprite();
        log.sprite[i].SetPosition(log.x + 20, log.y + 14 + i * 22, 11);
      }

    fun log_redraw ()
      {
        for (i = 0; i < LINES; i++)
          {
            # newest line at the bottom, older ones fade
            alpha = 0.35 + 0.65 * (i + 1) / LINES;
            log.sprite[i].SetImage(Image.Text(log.text[i], ${rgb colors.fg}, alpha, "${font} 11"));
          }
      }

    fun status_callback (text)
      {
        for (i = 0; i < LINES - 1; i++)
          log.text[i] = log.text[i + 1];
        log.text[LINES - 1] = text;
        log_redraw();
      }
    Plymouth.SetUpdateStatusFunction(status_callback);

    #------------------------------ passphrase ------------------------------
    pw.field.image = Image("field.png");
    pw.field.sprite = Sprite(pw.field.image);
    pw.x = X + W / 2 - pw.field.image.GetWidth() / 2;
    # Lower than the logo's wordmark (padding), above the status panel
    pw.y = Y + H * 0.75;
    pw.field.sprite.SetPosition(pw.x, pw.y, 20);
    pw.bullet_image = Image("bullet.png");
    pw.shown = 0;

    fun pw_opacity (o)
      {
        pw.field.sprite.SetOpacity(o);
        for (i = 0; pw.bullet[i]; i++)
          pw.bullet[i].SetOpacity(o);
      }
    pw_opacity(0);

    fun password_callback (prompt, bullets)
      {
        pw_opacity(1);
        for (i = 0; pw.bullet[i] || i < bullets; i++)
          {
            if (!pw.bullet[i])
              {
                pw.bullet[i] = Sprite(pw.bullet_image);
                pw.bullet[i].SetPosition(pw.x + 18 + i * 20,
                  pw.y + pw.field.image.GetHeight() / 2 - pw.bullet_image.GetHeight() / 2, 22);
              }
            if (i < bullets)
              pw.bullet[i].SetOpacity(1);
            else
              pw.bullet[i].SetOpacity(0);
          }
      }

    fun normal_callback ()
      {
        pw_opacity(0);
      }
    Plymouth.SetDisplayPasswordFunction(password_callback);
    Plymouth.SetDisplayNormalFunction(normal_callback);

    #------------------------------ messages ------------------------------
    msg.sprite = Sprite();
    msg.sprite.SetPosition(X + 20, Y + 20, 30);
    fun message_callback (text)
      {
        msg.sprite.SetImage(Image.Text(text, ${rgb colors.fg}, 1, "${font} 12"));
        msg.sprite.SetOpacity(1);
      }
    fun hide_message_callback (text)
      {
        msg.sprite.SetOpacity(0);
      }
    Plymouth.SetDisplayMessageFunction(message_callback);
    Plymouth.SetHideMessageFunction(hide_message_callback);
  '';
in
runCommand "nox-plymouth" { nativeBuildInputs = [ resvg ]; } ''
  d=$out/share/plymouth/themes/nox
  mkdir -p $d
  cp ${branding}/share/nox/wallpaper.png $d/background.png
  resvg ${panel 900 164} $d/log.png
  resvg ${panel 520 52} $d/field.png
  resvg ${bullet} $d/bullet.png
  cp ${script} $d/nox.script
  cat > $d/nox.plymouth <<EOF
  [Plymouth Theme]
  Name=NoX
  Description=NoX wallpaper, passphrase field and the boot in short form
  ModuleName=script

  [script]
  ImageDir=$d
  ScriptFile=$d/nox.script
  ConsoleLogBackgroundColor=0x${colors.bgDark}
  EOF
''
