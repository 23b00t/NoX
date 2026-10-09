# The libraries libxenvchan needs, without the rest of the Xen tools (the
# full xen package is ~550 MB with its closure, too much for every guest).
# RPATHs point into this package, so nothing references xen any more.
{
  runCommand,
  patchelf,
  xen,
}:
runCommand "nox-vchan-libs-${xen.version}" { nativeBuildInputs = [ patchelf ]; } ''
  mkdir -p $out/lib
  for lib in vchan gnttab evtchn store toollog toolcore; do
    cp -P ${xen}/lib/libxen$lib.so* $out/lib/
  done
  chmod u+w $out/lib/*
  for f in $out/lib/*; do
    [ -L "$f" ] || patchelf --set-rpath $out/lib "$f"
  done
''
