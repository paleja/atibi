# fstab-ro.awk - make the root and the firmware partition read-only in fstab.
#
#   awk -f image/fstab-ro.awk /etc/fstab > fstab.new
#
# It is a separate file rather than a quote inside build.sh for one reason: the
# suite can run it against the fstab a real card shipped (tests/fixtures/) and
# show the result, instead of trusting a program nobody has read since it was
# written inside a shell script.
#
# Why this exists at all: fstab is what mounts these partitions, and a line
# that says `defaults` remounts the root read-write even when the kernel command
# line says ro. The first card built this way ran with a writable root while
# every comment in the build said otherwise, and pulling the power out of a
# writable ext4 root is the failure this appliance is designed around.
#
# The options field is edited in place rather than the line rebuilt from fields,
# so the column alignment that makes the file readable by eye over ssh survives.
#
# Idempotent: a line that already has ro as a whole option is left alone, so
# running this twice cannot produce `defaults,ro,ro`.

function addro(line, opts,    at) {
    at = index(line, opts)
    if (at == 0) return line
    return substr(line, 1, at + length(opts) - 1) ",ro" substr(line, at + length(opts))
}

# The option string cannot match earlier on the line: the device is a PARTUUID
# and the mount point is a path.
$2 == "/" || $2 == "/boot/firmware" {
    if ($4 !~ /(^|,)ro(,|$)/) $0 = addro($0, $4)
}
{ print }
