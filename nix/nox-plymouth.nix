# plymouth theme "nox": the NoX wallpaper (nox-branding, the theme's colors)
# full screen, the passphrase in a translucent field below the logo ("Enter
# LUKS password" above it, the bullets centered), and the boot in short form:
# the last units systemd finished starting as "[  OK  ] <unit>" in a
# translucent panel at the bottom (older lines fade). Esc shows the full boot messages (plymouth's
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

  # Boot status panel: lines of 22 px, 14 px padding
  lines = 8;
  logW = 1040;
  logH = 28 + lines * 22;

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
    # systemd sends a unit's name when it finished starting (unit.c,
    # manager_send_unit_plymouth), so each line is an OK like on the console
    LINES = ${toString lines};
    LOG_FONT = "${font} 11";
    log.ok_dx = Image.Text("[  ", 1, 1, 1, 1, LOG_FONT).GetWidth();
    log.text_dx = Image.Text("[  OK  ] ", 1, 1, 1, 1, LOG_FONT).GetWidth();
    log.panel.image = Image("log.png");
    log.panel.sprite = Sprite(log.panel.image);
    log.x = X + W / 2 - log.panel.image.GetWidth() / 2;
    log.y = Y + H - log.panel.image.GetHeight() - H * 0.03;
    log.panel.sprite.SetPosition(log.x, log.y, 10);
    for (i = 0; i < LINES; i++)
      {
        log.text[i] = "";
        log.frame[i] = Sprite();
        log.frame[i].SetPosition(log.x + 20, log.y + 14 + i * 22, 11);
        log.ok[i] = Sprite();
        log.ok[i].SetPosition(log.x + 20 + log.ok_dx, log.y + 14 + i * 22, 11);
        log.sprite[i] = Sprite();
        log.sprite[i].SetPosition(log.x + 20 + log.text_dx, log.y + 14 + i * 22, 11);
      }

    fun log_redraw ()
      {
        for (i = 0; i < LINES; i++)
          {
            # newest line at the bottom, older ones fade
            alpha = 0.35 + 0.65 * (i + 1) / LINES;
            if (log.text[i] == "")
              {
                frame = "";
                ok = "";
              }
            else
              {
                frame = "[      ]";
                ok = "OK";
              }
            log.frame[i].SetImage(Image.Text(frame, ${rgb colors.fg}, alpha, LOG_FONT));
            log.ok[i].SetImage(Image.Text(ok, ${rgb colors.ok}, alpha, LOG_FONT));
            log.sprite[i].SetImage(Image.Text(log.text[i], ${rgb colors.fg}, alpha, LOG_FONT));
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
    pw.y = Math.Min(Y + H * 0.75, log.y - pw.field.image.GetHeight() - 24);
    pw.field.sprite.SetPosition(pw.x, pw.y, 20);
    pw.label.image = Image.Text("Enter LUKS password", ${rgb colors.fg}, 1, "${font} 12");
    pw.label.sprite = Sprite(pw.label.image);
    pw.label.sprite.SetPosition(X + W / 2 - pw.label.image.GetWidth() / 2,
      pw.y - pw.label.image.GetHeight() - 10, 20);
    pw.bullet_image = Image("bullet.png");

    fun pw_opacity (o)
      {
        pw.field.sprite.SetOpacity(o);
        pw.label.sprite.SetOpacity(o);
        for (i = 0; pw.bullet[i]; i++)
          pw.bullet[i].SetOpacity(o);
      }
    pw_opacity(0);

    fun password_callback (prompt, bullets)
      {
        pw_opacity(1);
        # The bullets centered in the field (16 px each, 20 px apart)
        bx = pw.x + pw.field.image.GetWidth() / 2 - (bullets * 20 - 4) / 2;
        by = pw.y + pw.field.image.GetHeight() / 2 - pw.bullet_image.GetHeight() / 2;
        for (i = 0; pw.bullet[i] || i < bullets; i++)
          {
            if (!pw.bullet[i])
              pw.bullet[i] = Sprite(pw.bullet_image);
            pw.bullet[i].SetPosition(bx + i * 20, by, 22);
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
  resvg ${panel logW logH} $d/log.png
  resvg ${panel 520 52} $d/field.png
  resvg ${bullet} $d/bullet.png
  cp ${script} $d/nox.script
  cat > $d/nox.plymouth <<EOF
  [Plymouth Theme]
  Name=NoX
  Description=NoX wallpaper, LUKS passphrase field and the boot in short form
  ModuleName=script

  [script]
  ImageDir=$d
  ScriptFile=$d/nox.script
  ConsoleLogBackgroundColor=0x${colors.bgDark}
  EOF
''
