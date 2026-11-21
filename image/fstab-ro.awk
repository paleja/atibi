# fstab-ro.awk: make root and firmware read-only in fstab. An fstab line
# saying `defaults` remounts the root read-write whatever the kernel command
# line says, and a writable ext4 root is what a hard power cut damages.
#
#   awk -f image/fstab-ro.awk /etc/fstab > fstab.new
#
# Edited in place, so the column alignment survives; idempotent; kept as a
# file so the suite can run it against a real card's fstab (tests/fixtures/).

function addro(line, opts,    at) {
    at = index(line, opts)
    if (at == 0) return line
    return substr(line, 1, at + length(opts) - 1) ",ro" substr(line, at + length(opts))
}

# Match on the mount point: PARTUUID and paths can repeat the field's text.
$2 == "/" || $2 == "/boot/firmware" {
    if ($4 !~ /(^|,)ro(,|$)/) $0 = addro($0, $4)
}
{ print }
