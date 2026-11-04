/* Positive-list filter for untrusted terminal output (stdin -> stdout).
   Keeps text (UTF-8 passes through), \n \r \t and the CSI sequences
   that only draw: SGR (m), cursor movement (A-H), erase (J, K) and
   ?25h/?25l, plus ?2026h/?2026l (synchronized output, nom wraps every
   redraw in it). Drops OSC, DCS/APC/PM/SOS, every other CSI (above all the
   ones a terminal answers, like n, c, t), other ESC sequences, C1
   controls (UTF-8 encoded U+0080-U+009F; raw bytes 0x80-0x9F are
   UTF-8 continuation bytes and pass) and the other C0 controls. A state
   machine across read boundaries, unbuffered: each read is written out
   right away (nom redraws without a newline). */
#include <errno.h>
#include <string.h>
#include <unistd.h>

enum { GROUND, C2, ESC, ESC_INTER, CSI, CSI_DROP, STR, STR_ESC };

static unsigned char csi[64];
static size_t csilen;

/* digits and ';' only, nothing else between "ESC [" and the final byte */
static int plain_params(void)
{
  for (size_t i = 2; i < csilen - 1; i++)
    if (!((csi[i] >= 0x30 && csi[i] <= 0x39) || csi[i] == 0x3B))
      return 0;
  return 1;
}

static int csi_allowed(void)
{
  unsigned char f = csi[csilen - 1];
  if (((csilen == 6 && memcmp(csi + 2, "?25", 3) == 0) ||
       (csilen == 8 && memcmp(csi + 2, "?2026", 5) == 0)) &&
      (f == 0x68 || f == 0x6C))
    return 1;
  if (!plain_params())
    return 0;
  return f == 0x6D || (f >= 0x41 && f <= 0x48) || f == 0x4A || f == 0x4B;
}

static int put(const void *p, size_t n)
{
  const char *c = p;
  while (n > 0) {
    ssize_t w = write(1, c, n);
    if (w < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    c += w;
    n -= (size_t)w;
  }
  return 0;
}

int main(void)
{
  unsigned char in[4096], out[4096 + 64];
  int st = GROUND;
  for (;;) {
    ssize_t n = read(0, in, sizeof in);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      break;
    size_t o = 0;
    for (ssize_t i = 0; i < n; i++) {
      unsigned char b = in[i];
      /* CAN/SUB abort any sequence; ESC starts a new one */
      if (st != GROUND && st != C2 && (b == 0x18 || b == 0x1A)) {
        st = GROUND;
        continue;
      }
      switch (st) {
      case C2:
        st = GROUND;
        if (b >= 0x80 && b <= 0x9F)
          continue; /* U+0080-U+009F */
        out[o++] = 0xC2;
        __attribute__((fallthrough)); /* b as text */
      case GROUND:
        if (b == 0x1B)
          st = ESC;
        else if (b == 0xC2)
          st = C2;
        else if (b == 0x0A || b == 0x0D || b == 0x09 || (b >= 0x20 && b != 0x7F))
          out[o++] = b;
        break;
      case ESC:
        if (b == 0x5B) { /* [ */
          st = CSI;
          csi[0] = 0x1B;
          csi[1] = b;
          csilen = 2;
        } else if (b == 0x5D || b == 0x50 || b == 0x5F || b == 0x5E || b == 0x58)
          st = STR; /* ] P _ ^ X */
        else if (b == 0x1B)
          st = ESC;
        else if (b >= 0x20 && b <= 0x2F)
          st = ESC_INTER;
        else
          st = GROUND; /* final byte (or garbage) of a dropped ESC sequence */
        break;
      case ESC_INTER:
        if (b == 0x1B)
          st = ESC;
        else if (!(b >= 0x20 && b <= 0x2F))
          st = GROUND;
        break;
      case CSI:
      case CSI_DROP:
        if (b == 0x1B) {
          st = ESC;
        } else if (b >= 0x40 && b <= 0x7E) {
          if (st == CSI) {
            csi[csilen++] = b;
            if (csi_allowed()) {
              memcpy(out + o, csi, csilen);
              o += csilen;
            }
          }
          st = GROUND;
        } else if (b >= 0x20 && b <= 0x3F) {
          if (st == CSI && csilen < sizeof csi - 1)
            csi[csilen++] = b;
          else
            st = CSI_DROP; /* too long: dropped */
        } else if (b < 0x20) {
          /* C0 inside CSI: dropped, the sequence goes on */
        } else {
          st = GROUND; /* not a CSI byte: sequence dropped */
        }
        break;
      case STR:
        if (b == 0x07)
          st = GROUND; /* BEL ends OSC */
        else if (b == 0x1B)
          st = STR_ESC;
        break;
      case STR_ESC:
        if (b == 0x5C) /* ESC \ = ST */
          st = GROUND;
        else {
          st = ESC; /* ESC ends the string and starts a new sequence */
          i--;
        }
        break;
      }
      if (o >= 4096) {
        if (put(out, o) < 0)
          return 1;
        o = 0;
      }
    }
    if (o > 0 && put(out, o) < 0)
      return 1;
  }
  /* a pending C2 at EOF was text */
  if (st == C2)
    return put("\xC2", 1) < 0;
  return 0;
}
