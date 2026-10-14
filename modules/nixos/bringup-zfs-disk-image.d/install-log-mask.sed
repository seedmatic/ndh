# The mask a failed install's log goes through on its way into the build log (prevm.sh): an age secret,
# and every line between a private-key header and its footer. Literals broken so this file does not match
# the guards it mirrors. Applied with `sed -E -f`.
s/AGE-SECRET[-]KEY-1[A-Z0-9]+/AGE-SECRET-KEY-1[MASKED]/g
/BEGIN [A-Z ]*PRIVATE[ ]KEY/,/END [A-Z ]*PRIVATE[ ]KEY/{
/BEGIN|END/!s/.*/[MASKED]/
}
